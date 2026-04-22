# nanvix workspace tasks
# Run `pj` (or `just`) to list available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Project root is the parent of .config/ (where this justfile lives).

ROOT := parent_directory(justfile_directory())
SCRIPTS := justfile_directory() / "scripts"

_default:
    @just --justfile {{ justfile() }} --list --unsorted

# Point basedpyright at a Python interpreter (accepts a venv dir or python binary).
venv *ARGS:
    uv run --script {{ SCRIPTS }}/pyright.py --project-root {{ ROOT }} {{ ARGS }}

# Workspace operations. Subcommands: `clean [--dry]`, `install-git [--check]`, `doctor`.
ws CMD *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="{{ justfile_directory() }}/scripts"
    case "{{ CMD }}" in
        clean)
            bash "$scripts/clean-workspace.sh" {{ ARGS }}
            ;;
        install-git)
            bash "$scripts/install-git.sh" {{ ARGS }}
            ;;
        doctor)
            bash "$scripts/install-git.sh" --check
            : "${PRIMARY_REPOS:?PRIMARY_REPOS not set (source .envrc)}"
            : "${GH_TOKEN:?GH_TOKEN not set (source .envrc)}"
            command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
            gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }
            echo "ok: git >= 2.48, PRIMARY_REPOS set, gh authenticated"
            ;;
        *)
            echo "error: unknown ws subcommand: {{ CMD }}" >&2
            echo "available: clean, install-git, doctor" >&2
            exit 2
            ;;
    esac
