#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "typer>=0.12",
#   "rich>=13",
# ]
# ///
"""Workspace health-check — renders a Rich table of checks and exits 0 if all pass.

Invocation:
  pj ws doctor               # check all repos; exit 1 on any FAIL row
  uv run --script .config/scripts/doctor.py

Checks git version, env vars (PROJECT_ROOT, PRIMARY_REPOS, GH_TOKEN), gh auth,
and per-repo bare-config invariants (repositoryformatversion, relativeWorktrees,
no prunable worktrees).  Depends on _common for env helpers and git wrappers.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

# Allow `import _common` regardless of cwd when uv runs this script.
sys.path.insert(0, str(Path(__file__).parent))

import _common  # noqa: E402

import typer  # noqa: E402
from rich.console import Console  # noqa: E402
from rich.table import Table  # noqa: E402

app = typer.Typer(add_completion=False)
console = Console(soft_wrap=True)

_VERSION_RE = re.compile(r"(\d+)\.(\d+)")

# ---------------------------------------------------------------------------
# Individual check functions — each returns (pass: bool, detail: str)
# ---------------------------------------------------------------------------


def check_git_version() -> tuple[bool, str]:
    """git >= 2.48"""
    try:
        result = subprocess.run(
            ["git", "--version"], capture_output=True, text=True, check=True
        )
        # "git version 2.50.1", "git version 2.48.0-rc1", etc.
        match = _VERSION_RE.search(result.stdout)
        if not match:
            return False, f"could not parse: {result.stdout.strip()!r}"
        major, minor = int(match.group(1)), int(match.group(2))
        ok = (major, minor) >= (2, 48)
        return ok, f"git {result.stdout.strip().split()[-1]}"
    except Exception as exc:
        return False, str(exc)


def check_project_root() -> tuple[bool, str]:
    """$PROJECT_ROOT set and parseable."""
    try:
        root = _common.project_root()
        return True, str(root)
    except SystemExit as exc:
        return False, str(exc)


def check_primary_repos() -> tuple[bool, str]:
    """$PRIMARY_REPOS set with >= 1 item."""
    try:
        repos = _common.primary_repos()
        ok = len(repos) >= 1
        return ok, f"{len(repos)} repo(s): {', '.join(repos)}"
    except SystemExit as exc:
        return False, str(exc)


def check_gh_token() -> tuple[bool, str]:
    """$GH_TOKEN set."""
    try:
        _common.gh_token()
        return True, "set"
    except SystemExit as exc:
        return False, str(exc)


def check_gh_auth() -> tuple[bool, str]:
    """`gh auth status` exits 0."""
    try:
        result = subprocess.run(
            ["gh", "auth", "status"], capture_output=True, text=True
        )
        ok = result.returncode == 0
        detail = "authenticated" if ok else (result.stderr.strip() or "not authenticated")
        return ok, detail
    except FileNotFoundError:
        return False, "gh CLI not found"
    except Exception as exc:
        return False, str(exc)


def check_repo_format_version(repo: _common.Repo) -> tuple[bool, str]:
    """core.repositoryformatversion == 1"""
    try:
        result = subprocess.run(
            ["git", "config", "-f", str(repo.bare / "config"), "core.repositoryformatversion"],
            capture_output=True, text=True,
            env={**os.environ, **_common.GIT_SAFE_ENV},
        )
        val = result.stdout.strip()
        if result.returncode != 0 and not val:
            return False, "key not set"
        ok = val == "1"
        detail = f"'{val}'" if ok else f"got '{val}', want '1'"
        return ok, detail
    except Exception as exc:
        return False, str(exc)


def check_repo_relative_worktrees(repo: _common.Repo) -> tuple[bool, str]:
    """extensions.relativeWorktrees == true"""
    try:
        result = subprocess.run(
            ["git", "config", "-f", str(repo.bare / "config"), "extensions.relativeWorktrees"],
            capture_output=True, text=True,
            env={**os.environ, **_common.GIT_SAFE_ENV},
        )
        val = result.stdout.strip()
        if result.returncode != 0 and not val:
            return False, "key not set"
        ok = val == "true"
        detail = f"'{val}'" if ok else f"got '{val}', want 'true'"
        return ok, detail
    except Exception as exc:
        return False, str(exc)


def check_repo_no_prunable(repo: _common.Repo) -> tuple[bool, str]:
    """No prunable worktrees."""
    try:
        result = subprocess.run(
            ["git", "worktree", "list", "--porcelain"],
            capture_output=True, text=True, check=False,
            env={**os.environ, **_common.GIT_SAFE_ENV},
            cwd=str(repo.bare),
        )
        prunable_count = result.stdout.count("prunable")
        ok = prunable_count == 0
        detail = "none" if ok else f"{prunable_count} prunable worktree(s)"
        return ok, detail
    except Exception as exc:
        return False, str(exc)


# ---------------------------------------------------------------------------
# Render helpers
# ---------------------------------------------------------------------------


def _status(ok: bool) -> str:
    return "[green]PASS[/]" if ok else "[red]FAIL[/]"


def add_row(table: Table, check: str, ok: bool, detail: str) -> None:
    table.add_row(check, _status(ok), detail)


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------


@app.command()
def main(
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Workspace health-check."""
    # Resolve project root (CLI flag wins over env)
    if project_root:
        os.environ["PROJECT_ROOT"] = project_root

    if not os.environ.get("PROJECT_ROOT"):
        console.print(
            "[red]error:[/] PROJECT_ROOT is not set and --project-root was not passed.\n"
            "Run via `pj doctor` or pass --project-root explicitly."
        )
        raise typer.Exit(2)

    table = Table(title="Workspace Doctor", show_header=True, header_style="bold")
    table.add_column("Check", style="bold")
    table.add_column("Status")
    table.add_column("Detail")

    all_pass = True

    def record(check: str, ok: bool, detail: str) -> None:
        nonlocal all_pass
        if not ok:
            all_pass = False
        add_row(table, check, ok, detail)

    # --- Global checks (cache root + repos so per-repo loop reuses results) ---
    record("git >= 2.48", *check_git_version())

    pr_ok, pr_detail = check_project_root()
    record("PROJECT_ROOT set", pr_ok, pr_detail)

    repos_ok, repos_detail = check_primary_repos()
    record("PRIMARY_REPOS set", repos_ok, repos_detail)

    record("GH_TOKEN set", *check_gh_token())
    record("gh authenticated", *check_gh_auth())

    # --- Per-repo checks (only if global env is sane) ---
    if not (pr_ok and repos_ok):
        console.print(table)
        raise typer.Exit(0 if all_pass else 1)

    root = _common.project_root()
    repo_names = _common.primary_repos()

    for name in repo_names:
        base = root / name
        bare = base / ".bare"
        repo = _common.Repo(
            name=name,
            base=base,
            bare=bare,
            slug=f"{_common.PRIMARY_OWNER}/{name}",
        )

        if not repo.is_bootstrapped:
            record(f"{name}: not bootstrapped", False, "bare dir missing")
            continue

        record(f"{name}: core.repositoryformatversion=1", *check_repo_format_version(repo))
        record(f"{name}: extensions.relativeWorktrees=true", *check_repo_relative_worktrees(repo))
        record(f"{name}: no prunable worktrees", *check_repo_no_prunable(repo))

    console.print(table)
    raise typer.Exit(0 if all_pass else 1)


if __name__ == "__main__":
    app()
