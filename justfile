# nanvix workspace tasks
# Run `pj` (or `just`) to list available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Project root is the parent of .config/ (where this justfile lives).

ROOT := parent_directory(justfile_directory())

_default:
    @just --justfile {{ justfile() }} --list --unsorted

# Point basedpyright at a Python interpreter (accepts a venv dir or python binary).
venv *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="{{ ROOT }}/.zed/settings.json"
    command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

    args=({{ ARGS }})
    key='.lsp.basedpyright.settings.python.pythonPath'

    if [[ ${#args[@]} -eq 0 || "${args[0]}" == "--show" ]]; then
        jq -r "$key" "$settings"
        exit 0
    fi

    raw="${args[0]}"
    if [[ "$raw" = /* ]]; then
        target="$raw"
    else
        target="{{ invocation_directory() }}/$raw"
    fi
    target="$(realpath -m "$target")"

    # If a directory was given, find a venv inside it (any depth, shallow first).
    # Accepts: a venv dir directly, or any ancestor directory containing one.
    if [[ -d "$target" ]]; then
        if [[ ! -f "$target/pyvenv.cfg" ]]; then
            mapfile -t found < <(find "$target" -maxdepth 6 -name pyvenv.cfg \
                -not -path '*/node_modules/*' -printf '%d %h\n' 2>/dev/null \
                | sort -n | awk '{print $2}')
            if [[ ${#found[@]} -eq 0 ]]; then
                echo "error: no venv (pyvenv.cfg) found under $target" >&2
                exit 1
            fi
            if [[ ${#found[@]} -gt 1 ]]; then
                echo "error: multiple venvs under $target; pass one explicitly:" >&2
                printf '  %s\n' "${found[@]}" >&2
                exit 1
            fi
            target="${found[0]}"
        fi
        for cand in "$target/bin/python" "$target/bin/python3" "$target/Scripts/python.exe"; do
            if [[ -x "$cand" ]]; then
                target="$cand"
                break
            fi
        done
    fi

    if [[ ! -x "$target" ]]; then
        echo "error: not an executable python: $target" >&2
        exit 1
    fi

    tmp="$(mktemp)"
    jq --arg p "$target" "$key = \$p" "$settings" > "$tmp"
    mv "$tmp" "$settings"
    echo "basedpyright pythonPath -> $target"
    echo "(Zed will reload settings.json automatically; restart the LSP if it doesn't pick up.)"

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
