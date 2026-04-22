"""Shared stdlib-only helpers for `.config/scripts/*.py` uv scripts."""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import shutil
import subprocess
import sys
from typing import Optional

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


def run(
    argv: list[str],
    *,
    cwd: Optional[pathlib.Path] = None,
    check: bool = True,
    capture: bool = False,
    extra_env: Optional[dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    """Run *argv*, optionally capturing stdout, with merged env."""
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
    cwd: Optional[pathlib.Path] = None,
    check: bool = True,
) -> subprocess.CompletedProcess:
    """Equivalent to: run(['git', *args], cwd=cwd, check=check, extra_env=GIT_SAFE_ENV)."""
    return run(["git", *args], cwd=cwd, check=check, extra_env=GIT_SAFE_ENV)


def git_capture(*args: str, cwd: Optional[pathlib.Path] = None) -> str:
    """git(...) with capture=True; returns stdout.strip()."""
    result = run(
        ["git", *args],
        cwd=cwd,
        check=True,
        capture=True,
        extra_env=GIT_SAFE_ENV,
    )
    return result.stdout.strip()


def gh_default_branch(slug: str) -> str:
    """gh repo view <slug> --json defaultBranchRef -q .defaultBranchRef.name"""
    result = run(
        ["gh", "repo", "view", slug, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"],
        capture=True,
    )
    return result.stdout.strip()


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
    name: str                      # subdir name under .bare/worktrees/
    branch: Optional[str]          # parsed from HEAD; None if detached/unparseable
    wt_dir: pathlib.Path           # .bare/worktrees/<name>/
    checkout: Optional[pathlib.Path]  # resolved working-tree path, or None if orphan
    gitdir_raw: str                # raw contents of .bare/worktrees/<name>/gitdir


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
        branch: Optional[str] = None
        if head_file.exists():
            head_raw = head_file.read_text().strip()
            prefix = "ref: refs/heads/"
            if head_raw.startswith(prefix):
                branch = head_raw[len(prefix):]

        # Parse gitdir
        gitdir_file = wt_dir / "gitdir"
        gitdir_raw = ""
        checkout: Optional[pathlib.Path] = None

        if gitdir_file.exists():
            gitdir_raw = gitdir_file.read_text().strip()
            gd = gitdir_raw

            # Resolution rules matching clean-workspace.sh:128-131
            if gd.startswith("/"):
                # absolute: strip trailing /.git
                wt_path = pathlib.Path(gd[: -len("/.git")] if gd.endswith("/.git") else gd)
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
