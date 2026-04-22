"""Shared stdlib-only helpers for `.config/scripts/*.py` uv scripts.

This module is imported directly (no PEP 723 header) because it has no
third-party dependencies.  Every uv script that needs env reads, git/gh
subprocess wrappers, or the Repo/Worktree dataclasses should ``import _common``
(scripts directory must be on sys.path, which ``uv run --script`` ensures for
co-located files).

Public API summary:
  project_root(), primary_repos(), gh_token()   — env / path helpers
  run(), git(), git_capture(), gh_default_branch() — subprocess wrappers
  Repo, Worktree, discover_worktrees()           — bare-repo dataclasses
"""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import subprocess
import sys
from typing import Literal, overload

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PRIMARY_OWNER: str = os.environ.get("PRIMARY_OWNER", "nanvix")

GIT_SAFE_ENV: dict[str, str] = {
    "GIT_CONFIG_COUNT": "1",
    "GIT_CONFIG_KEY_0": "safe.directory",
    "GIT_CONFIG_VALUE_0": "*",
}

# ---------------------------------------------------------------------------
# Env / paths
# ---------------------------------------------------------------------------


def project_root() -> pathlib.Path:
    """$PROJECT_ROOT, or raise SystemExit(2) with a helpful message."""
    val = os.environ.get("PROJECT_ROOT")
    if not val:
        sys.exit(
            "error: PROJECT_ROOT not set — run `direnv allow` in the workspace root,"
            " or set PROJECT_ROOT manually."
        )
    return pathlib.Path(val)


def primary_repos() -> list[str]:
    """$PRIMARY_REPOS split on whitespace, or SystemExit(2)."""
    val = os.environ.get("PRIMARY_REPOS")
    if not val:
        sys.exit(
            "error: PRIMARY_REPOS not set — run `direnv allow` in the workspace root,"
            " or set PRIMARY_REPOS manually."
        )
    return val.split()


def gh_token() -> str:
    """$GH_TOKEN, or SystemExit(2)."""
    val = os.environ.get("GH_TOKEN")
    if not val:
        sys.exit(
            "error: GH_TOKEN not set — run `direnv allow` in the workspace root,"
            " or set GH_TOKEN manually."
        )
    return val


# ---------------------------------------------------------------------------
# Subprocess wrappers
# ---------------------------------------------------------------------------


@overload
def run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = ...,
    check: bool = ...,
    capture: Literal[True],
    extra_env: dict[str, str] | None = ...,
) -> subprocess.CompletedProcess[str]: ...


@overload
def run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = ...,
    check: bool = ...,
    capture: Literal[False] = ...,
    extra_env: dict[str, str] | None = ...,
) -> subprocess.CompletedProcess[str]: ...


def run(
    argv: list[str],
    *,
    cwd: pathlib.Path | None = None,
    check: bool = True,
    capture: bool = False,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run *argv*, optionally capturing stdout, with merged env.

    When ``capture=False``, ``result.stdout`` is ``None``. When ``capture=True``
    it is a ``str`` (because ``text=True``).
    """
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        argv,
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=None,
        env=env,
    )


def git(
    *args: str,
    cwd: pathlib.Path | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Equivalent to: run(['git', *args], cwd=cwd, check=check, extra_env=GIT_SAFE_ENV)."""
    return run(["git", *args], cwd=cwd, check=check, extra_env=GIT_SAFE_ENV)


def git_capture(*args: str, cwd: pathlib.Path | None = None) -> str:
    """git(...) with capture=True; returns stdout.strip()."""
    result = run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture=True,
        extra_env=GIT_SAFE_ENV,
    )
    assert result.stdout is not None  # capture=True ⇒ stdout is str
    return result.stdout.strip()


def gh_default_branch(slug: str) -> str:
    """gh repo view <slug> --json defaultBranchRef -q .defaultBranchRef.name.

    Raises ``RuntimeError`` if gh fails or returns empty output. Callers that
    want "log and continue" semantics (e.g. ``clean.py``) should catch this.
    """
    result = run(
        ["gh", "repo", "view", slug, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"],
        capture=True,
        check=False,
    )
    branch = result.stdout.strip() if result.stdout else ""
    if result.returncode != 0 or not branch:
        raise RuntimeError(
            f"could not determine default branch for {slug!r} (exit={result.returncode})"
        )
    return branch


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Repo:
    name: str              # e.g. "zutils"
    base: pathlib.Path     # $PROJECT_ROOT/<name>
    bare: pathlib.Path     # base / ".bare"
    slug: str              # f"{PRIMARY_OWNER}/{name}"

    @property
    def is_bootstrapped(self) -> bool:
        return self.bare.is_dir()


@dataclasses.dataclass(frozen=True)
class Worktree:
    name: str                           # subdir name under .bare/worktrees/
    branch: str | None                  # parsed from HEAD; None if detached/unparseable
    wt_dir: pathlib.Path                # .bare/worktrees/<name>/
    checkout: pathlib.Path | None       # resolved working-tree path, or None if orphan
    gitdir_raw: str                     # raw contents of .bare/worktrees/<name>/gitdir


def discover_worktrees(repo: Repo) -> list[Worktree]:
    """Enumerate <bare>/worktrees/* and parse HEAD + gitdir."""
    worktrees_dir = repo.bare / "worktrees"
    if not worktrees_dir.is_dir():
        return []

    results: list[Worktree] = []

    for wt_dir in sorted(worktrees_dir.iterdir()):
        if not wt_dir.is_dir():
            continue

        # Parse branch from HEAD
        head_file = wt_dir / "HEAD"
        branch: str | None = None
        if head_file.exists():
            head_raw = head_file.read_text().strip()
            prefix = "ref: refs/heads/"
            if head_raw.startswith(prefix):
                branch = head_raw[len(prefix):]

        # Parse gitdir
        gitdir_file = wt_dir / "gitdir"
        gitdir_raw = ""
        checkout: pathlib.Path | None = None

        if gitdir_file.exists():
            gitdir_raw = gitdir_file.read_text().strip()
            gd = gitdir_raw

            # Resolution rules matching clean-workspace.sh:128-131
            if gd.startswith("/"):
                # absolute: drop the trailing `.git` component if present
                p = pathlib.Path(gd)
                wt_path = p.parent if p.name == ".git" else p
            else:
                # relative: resolve from wt_dir
                wt_path = (wt_dir / gd).resolve().parent

            # Verify checkout exists (has .git)
            if (wt_path / ".git").exists():
                checkout = wt_path
            else:
                checkout = None  # orphan

        results.append(
            Worktree(
                name=wt_dir.name,
                branch=branch,
                wt_dir=wt_dir,
                checkout=checkout,
                gitdir_raw=gitdir_raw,
            )
        )

    return results


# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    root = project_root()
    repos_names = primary_repos()

    output: dict = {
        "project_root": str(root),
        "primary_repos": repos_names,
        "worktrees": {},
    }

    for repo_name in repos_names:
        base = root / repo_name
        bare = base / ".bare"
        repo = Repo(
            name=repo_name,
            base=base,
            bare=bare,
            slug=f"{PRIMARY_OWNER}/{repo_name}",
        )
        wts = discover_worktrees(repo)
        output["worktrees"][repo_name] = [
            {
                "name": wt.name,
                "branch": wt.branch,
                "checkout": str(wt.checkout) if wt.checkout else None,
                "gitdir_raw": wt.gitdir_raw,
            }
            for wt in wts
        ]

    print(json.dumps(output, indent=2))
