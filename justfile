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

# Workspace operations. Subcommands: `clean [--dry]`, `install-git [--check]`, `doctor`, `wt <add|switch|rm|ls|status>`.
ws CMD *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts="{{ justfile_directory() }}/scripts"
    case "{{ CMD }}" in
        clean)
            exec uv run --script "{{ SCRIPTS }}/clean.py" --project-root "{{ ROOT }}" {{ ARGS }}
            ;;
        install-git)
            bash "$scripts/install-git.sh" {{ ARGS }}
            ;;
        doctor)
            uv run --script "{{ SCRIPTS }}/doctor.py" --project-root "{{ ROOT }}" {{ ARGS }}
            ;;
        wt)
            exec bash "$scripts/wt.sh" {{ ARGS }}
            ;;
        *)
            echo "error: unknown ws subcommand: {{ CMD }}" >&2
            echo "available: clean, install-git, doctor, wt" >&2
            exit 2
            ;;
    esac
