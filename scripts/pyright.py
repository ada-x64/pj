#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "typer>=0.12",
#   "rich>=13",
# ]
# ///
"""Point basedpyright at a Python interpreter (accepts a venv dir or python binary)."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import typer
from rich.console import Console

app = typer.Typer(add_completion=False)
console = Console(markup=False, soft_wrap=True)

KEY_PATH = ("lsp", "basedpyright", "settings", "python", "pythonPath")
MAX_VENV_DEPTH = 6  # max directory depth (relative to target) to search for pyvenv.cfg


def _get_nested(d: dict, keys: tuple[str, ...]) -> str:
    cur = d
    for k in keys:
        if not isinstance(cur, dict):
            return ""
        cur = cur.get(k, "")
    return cur if isinstance(cur, str) else ""


def _set_nested(d: dict, keys: tuple[str, ...], value: str) -> None:
    cur = d
    for k in keys[:-1]:
        cur = cur.setdefault(k, {})
    cur[keys[-1]] = value


def _find_venv_python(target: Path) -> Path:
    """Given a directory, locate a single venv and return its python binary."""
    # If target itself is a venv, use it directly.
    if not (target / "pyvenv.cfg").exists():
        # Search for pyvenv.cfg up to MAX_VENV_DEPTH directories deep.
        # rglob yields a Path like <target>/<a>/<b>/pyvenv.cfg; the venv dir is
        # the parent, so its depth (in parts) equals len(rel.parts) - 1.
        # Therefore len(rel.parts) <= MAX_VENV_DEPTH + 1.
        found: list[Path] = []
        try:
            for cfg in target.rglob("pyvenv.cfg"):
                rel = cfg.relative_to(target)
                if len(rel.parts) <= MAX_VENV_DEPTH + 1:
                    if "node_modules" not in rel.parts:
                        found.append(cfg.parent)
        except Exception:
            pass

        # sort by depth
        found.sort(key=lambda p: len(p.relative_to(target).parts))

        if len(found) == 0:
            raise typer.BadParameter(f"no venv (pyvenv.cfg) found under {target}")
        if len(found) > 1:
            paths = "\n  ".join(str(p) for p in found)
            raise typer.BadParameter(
                f"multiple venvs under {target}; pass one explicitly:\n  {paths}"
            )
        target = found[0]

    # Resolve python binary
    for cand_rel in ("bin/python", "bin/python3", "Scripts/python.exe"):
        cand = target / cand_rel
        if cand.exists() and os.access(cand, os.X_OK):
            return cand

    raise typer.BadParameter(f"no executable python found in venv {target}")


@app.command()
def main(
    path: str | None = typer.Argument(None),
    show: bool = typer.Option(False, "--show"),
    project_root: str | None = typer.Option(None, "--project-root", hidden=True),
) -> None:
    """Point basedpyright at a Python interpreter (venv dir or python binary)."""
    root = Path(project_root) if project_root else Path(os.environ.get("PROJECT_ROOT", ""))
    if not root or not root.exists():
        console.print(
            "error: PROJECT_ROOT is not set and no --project-root was passed."
            " Run via `pj`/`just` so the workspace root is propagated."
        )
        raise typer.Exit(2)

    settings_file = root / ".zed" / "settings.json"

    if not settings_file.exists():
        console.print(f"error: settings file not found: {settings_file}")
        raise typer.Exit(1)

    settings_text = settings_file.read_text()
    try:
        settings: dict = json.loads(settings_text)
    except json.JSONDecodeError as exc:
        console.print(f"error: {settings_file} is not valid JSON: {exc}")
        raise typer.Exit(1) from exc

    # --show or no args
    if path is None or show:
        current = _get_nested(settings, KEY_PATH)
        console.print(current)
        return

    # Resolve path
    raw = path
    if os.path.isabs(raw):
        target = Path(raw)
    else:
        # Use PWD (the invocation directory) for relative path resolution
        pwd = os.environ.get("PWD") or str(Path.cwd())
        target = Path(pwd) / raw

    target = target.resolve()

    if target.is_dir():
        target = _find_venv_python(target)

    if not (target.exists() and os.access(target, os.X_OK)):
        console.print(f"error: not an executable python: {target}")
        raise typer.Exit(1)

    # Atomic write: write to temp in same dir, then replace
    _set_nested(settings, KEY_PATH, str(target))
    new_text = json.dumps(settings, indent=2) + "\n"

    parent = settings_file.parent
    fd, tmp_path = tempfile.mkstemp(dir=parent)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(new_text)
        os.replace(tmp_path, settings_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    console.print(f"basedpyright pythonPath -> {target}")
    console.print("(Zed will reload settings.json automatically; restart the LSP if it doesn't pick up.)")


if __name__ == "__main__":
    app()
