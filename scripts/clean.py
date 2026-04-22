#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "typer>=0.12",
#   "rich>=13",
# ]
# ///
"""Workspace cleanup — enforces primary-repo + default-branch invariants."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Annotated, Callable

# Allow `import _common` regardless of cwd when uv runs this script.
sys.path.insert(0, str(Path(__file__).parent))

import _common  # noqa: E402

import typer  # noqa: E402
from rich.console import Console  # noqa: E402

app = typer.Typer(add_completion=False)
console = Console()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def maybe(dry: bool, action: str, fn: Callable[[], None]) -> None:
    """In dry mode, print 'would-do: <action>'; otherwise print 'doing: <action>' and run fn()."""
    if dry:
        console.print(f"  would-do: {action}")
    else:
        console.print(f"  doing: {action}")
        fn()


def _resolve_project_root(project_root: str | None) -> None:
    """Resolve --project-root flag → os.environ['PROJECT_ROOT']. Exit 2 if neither set."""
    if project_root:
        os.environ["PROJECT_ROOT"] = project_root
    if not os.environ.get("PROJECT_ROOT"):
        console.print(
            "[red]error:[/] PROJECT_ROOT is not set and --project-root was not passed.\n"
            "Run via `pj ws clean` or pass --project-root explicitly."
        )
        raise typer.Exit(2)


# ---------------------------------------------------------------------------
# Phase functions
# ---------------------------------------------------------------------------


def _delete_non_primary(dry: bool) -> None:
    """Phase 0: remove top-level dirs not in PRIMARY_REPOS.

    Mirrors the bash glob `"$ROOT"/*/` which (without `dotglob`) skips
    hidden directories. We must NOT touch `.config`, `.agents`, etc.
    """
    console.print("=== Phase 0: prune non-primary top-level dirs ===")
    root = _common.project_root()
    keep = set(_common.primary_repos())
    for d in sorted(root.iterdir()):
        if not d.is_dir() or d.is_symlink():
            continue
        if d.name.startswith("."):
            continue  # match bash glob behavior — never touch dotfiles
        if d.name in keep:
            continue
        console.print(f"  not primary: {d.name}")
        maybe(dry, f"rm -rf {d}", lambda d=d: shutil.rmtree(d))


def _bootstrap_missing(dry: bool) -> None:
    """Phase 1a: clone bare repos that are absent."""
    root = _common.project_root()
    owner = _common.PRIMARY_OWNER
    for name in _common.primary_repos():
        base = root / name
        bare = base / ".bare"
        slug = f"{owner}/{name}"
        console.print(f"\n=== {name} ===")
        if not bare.is_dir():
            console.print(f"  no .bare — bootstrapping from https://github.com/{slug}")
            maybe(dry, f"mkdir -p {base}", lambda base=base: base.mkdir(parents=True, exist_ok=True))
            maybe(
                dry,
                f"git clone --bare https://github.com/{slug} {bare}",
                lambda slug=slug, bare=bare: _common.git("clone", "--bare", f"https://github.com/{slug}", str(bare)),
            )
            git_file = base / ".git"
            maybe(
                dry,
                f"write {git_file} -> 'gitdir: ./.bare'",
                lambda git_file=git_file: git_file.write_text("gitdir: ./.bare\n"),
            )
            # Skip remaining per-repo work in dry mode (bare still doesn't exist)
            if dry:
                console.print(f"  (dry: would set up {bare} and continue)")
                continue
        else:
            console.print(f"  already bootstrapped: {bare}")


def _normalize_bare_config(dry: bool) -> None:
    """Phase 1b: set repositoryformatversion=1, relativeWorktrees=true, HEAD, fetch."""
    root = _common.project_root()
    owner = _common.PRIMARY_OWNER
    for name in _common.primary_repos():
        base = root / name
        bare = base / ".bare"
        slug = f"{owner}/{name}"
        console.print(f"\n=== {name} ===")

        if not bare.is_dir():
            console.print(f"  (bare missing — skip)")
            continue

        maybe(
            dry,
            f"git config -f {bare}/config core.repositoryformatversion 1",
            lambda bare=bare: _common.git(
                "config", "-f", str(bare / "config"),
                "core.repositoryformatversion", "1",
            ),
        )
        maybe(
            dry,
            f"git config -f {bare}/config extensions.relativeWorktrees true",
            lambda bare=bare: _common.git(
                "config", "-f", str(bare / "config"),
                "extensions.relativeWorktrees", "true",
            ),
        )

        try:
            default = _common.gh_default_branch(slug)
        except RuntimeError as exc:
            console.print(f"  ERROR: {exc}; skipping")
            continue

        console.print(f"  default branch: {default}")

        maybe(
            dry,
            f"git -C {bare} symbolic-ref HEAD refs/heads/{default}",
            lambda bare=bare, default=default: _common.git(
                "-C", str(bare), "symbolic-ref", "HEAD", f"refs/heads/{default}",
            ),
        )

        # Fetch may legitimately fail (network down, auth lapsed); don't abort
        # the whole phase — log and move on to the next repo.
        def _fetch(bare=bare, name=name) -> None:
            try:
                _common.git("-C", str(bare), "fetch", "--all", "--prune", "--quiet")
            except subprocess.CalledProcessError as exc:
                console.print(f"  [yellow]warning:[/] fetch failed for {name}: {exc}")

        maybe(
            dry,
            f"git -C {bare} fetch --all --prune --quiet",
            _fetch,
        )


def _prune_merged_worktrees(dry: bool) -> None:
    """Phase 1c: remove merged and orphan worktrees."""
    root = _common.project_root()
    owner = _common.PRIMARY_OWNER
    for name in _common.primary_repos():
        base = root / name
        bare = base / ".bare"
        slug = f"{owner}/{name}"
        console.print(f"\n=== {name} ===")

        if not bare.is_dir():
            console.print(f"  (bare missing — skip)")
            continue

        try:
            default = _common.gh_default_branch(slug)
        except RuntimeError as exc:
            console.print(f"  ERROR: {exc}; skipping")
            continue

        remote_default = f"origin/{default}"

        for wt in _common.discover_worktrees(_common.Repo(name=name, base=base, bare=bare, slug=slug)):
            # Default-branch worktree: keep
            if wt.branch == default:
                console.print(f"  keep [{wt.name}] {wt.branch} (default)")
                continue

            # Detached HEAD: cannot resolve "merged into default"; keep conservatively.
            if wt.branch is None:
                console.print(f"  keep [{wt.name}] (detached HEAD — cannot resolve merge state)")
                continue

            # Orphan registration (no local checkout)
            if wt.checkout is None:
                console.print(f"  orphan reg [{wt.name}] {wt.branch} -> drop")
                maybe(dry, f"rm -rf {wt.wt_dir}", lambda wt=wt: shutil.rmtree(wt.wt_dir))
                continue

            # Merged into origin/default -> delete
            result = _common.run(
                ["git", "-C", str(bare), "merge-base", "--is-ancestor",
                 wt.branch, remote_default],
                check=False,
                extra_env=_common.GIT_SAFE_ENV,
            )
            if result.returncode == 0:
                checkout = wt.checkout
                console.print(f"  merged [{wt.name}] {wt.branch} -> remove {checkout}")

                def _rm_merged(checkout=checkout, wt=wt, base=base) -> None:
                    shutil.rmtree(checkout)
                    shutil.rmtree(wt.wt_dir)
                    parent = checkout.parent
                    if parent != base and parent.is_dir() and not any(parent.iterdir()):
                        parent.rmdir()

                maybe(
                    dry,
                    f"rm -rf {checkout} {wt.wt_dir}",
                    _rm_merged,
                )
            else:
                console.print(f"  keep [{wt.name}] {wt.branch} (unmerged)")

        # Prune stale registrations
        maybe(
            dry,
            f"git -C {bare} worktree prune",
            lambda bare=bare: _common.git("-C", str(bare), "worktree", "prune"),
        )


def _ensure_default_worktree(dry: bool) -> None:
    """Phase 1d: create default-branch worktree if absent."""
    root = _common.project_root()
    owner = _common.PRIMARY_OWNER
    for name in _common.primary_repos():
        base = root / name
        bare = base / ".bare"
        slug = f"{owner}/{name}"
        console.print(f"\n=== {name} ===")

        if not bare.is_dir():
            console.print(f"  (bare missing — skip)")
            continue

        try:
            default = _common.gh_default_branch(slug)
        except RuntimeError as exc:
            console.print(f"  ERROR: {exc}; skipping")
            continue

        default_wt = base / default
        if not (default_wt / ".git").exists():
            console.print(f"  add default worktree at {default_wt}")
            maybe(
                dry,
                f"git -C {bare} worktree add {default_wt} {default}",
                lambda bare=bare, default_wt=default_wt, default=default: _common.git(
                    "-C", str(bare), "worktree", "add", str(default_wt), default,
                ),
            )
        else:
            console.print(f"  default worktree exists: {default_wt}")


def _rewrite_gitdirs_relative(dry: bool) -> None:
    """Phase 1e: rewrite both sides of every worktree's gitdir to relative paths."""
    root = _common.project_root()
    owner = _common.PRIMARY_OWNER
    for name in _common.primary_repos():
        base = root / name
        bare = base / ".bare"
        slug = f"{owner}/{name}"
        console.print(f"\n=== {name} ===")

        if not bare.is_dir():
            console.print(f"  (bare missing — skip)")
            continue

        for wt in _common.discover_worktrees(_common.Repo(name=name, base=base, bare=bare, slug=slug)):
            if wt.checkout is None:
                continue  # orphan — skip
            checkout = wt.checkout
            try:
                rel_wtpath = checkout.relative_to(base)
            except ValueError:
                console.print(f"  [yellow]warning:[/] {checkout} is outside {base}; skipping")
                continue
            depth = len(rel_wtpath.parts)
            up = "../" * depth
            new_checkout_gitdir = f"gitdir: {up}.bare/worktrees/{wt.name}\n"
            new_wt_gitdir = f"../../../{rel_wtpath}/.git\n"
            console.print(f"  relativize [{wt.name}] {rel_wtpath}")

            def _rewrite(checkout=checkout, wt=wt, ncg=new_checkout_gitdir, nwg=new_wt_gitdir) -> None:
                (checkout / ".git").write_text(ncg)
                (wt.wt_dir / "gitdir").write_text(nwg)

            maybe(
                dry,
                f"rewrite gitdirs for {rel_wtpath}",
                _rewrite,
            )


# ---------------------------------------------------------------------------
# Typer commands
# ---------------------------------------------------------------------------


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Workspace cleanup — run all phases in order, or invoke a subcommand."""
    _resolve_project_root(project_root)
    if ctx.invoked_subcommand is None:
        _delete_non_primary(dry)
        _bootstrap_missing(dry)
        _normalize_bare_config(dry)
        _prune_merged_worktrees(dry)
        _ensure_default_worktree(dry)
        _rewrite_gitdirs_relative(dry)
        console.print()
        if dry:
            console.print("=== done (dry — no changes made; re-run without --dry to apply) ===")
        else:
            console.print("=== done ===")


@app.command("delete-non-primary")
def delete_non_primary(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Remove top-level dirs not in PRIMARY_REPOS."""
    _resolve_project_root(project_root)
    _delete_non_primary(dry)


@app.command("bootstrap-missing")
def bootstrap_missing(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Clone bare repos that are absent."""
    _resolve_project_root(project_root)
    _bootstrap_missing(dry)


@app.command("normalize-bare-config")
def normalize_bare_config(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Set repositoryformatversion=1, relativeWorktrees=true, HEAD, and fetch."""
    _resolve_project_root(project_root)
    _normalize_bare_config(dry)


@app.command("prune-merged-worktrees")
def prune_merged_worktrees(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Remove merged and orphan worktrees."""
    _resolve_project_root(project_root)
    _prune_merged_worktrees(dry)


@app.command("ensure-default-worktree")
def ensure_default_worktree(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Create default-branch worktree if absent."""
    _resolve_project_root(project_root)
    _ensure_default_worktree(dry)


@app.command("rewrite-gitdirs-relative")
def rewrite_gitdirs_relative(
    dry: Annotated[bool, typer.Option("--dry", "-n", help="Preview without making changes")] = False,
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Rewrite both sides of every worktree's gitdir to relative paths."""
    _resolve_project_root(project_root)
    _rewrite_gitdirs_relative(dry)


if __name__ == "__main__":
    app()
