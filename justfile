# nanvix workspace tasks
# Run `pj` (or `just`) to list available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Project root is the parent of .config/ (where this justfile lives).

ROOT := parent_directory(justfile_directory())

_default:
    @just --justfile {{ justfile() }} --list --unsorted

# Configure or inspect basedpyright.
pyright *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="{{ ROOT }}/.zed/settings.json"
    command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

    args=({{ ARGS }})
    if [[ ${#args[@]} -eq 0 || "${args[0]}" == "--show" ]]; then
        jq -r '.lsp.basedpyright.settings."basedpyright.analysis".configFilePath' "$settings"
        exit 0
    fi

    raw="${args[0]}"
    if [[ "$raw" = /* ]]; then
        target="$raw"
    else
        target="{{ invocation_directory() }}/$raw"
    fi
    target="$(realpath -m "$target")"

    if [[ ! -e "$target" ]]; then
        echo "error: path does not exist: $target" >&2
        exit 1
    fi

    tmp="$(mktemp)"
    jq --arg p "$target" \
        '.lsp.basedpyright.settings."basedpyright.analysis".configFilePath = $p' \
        "$settings" > "$tmp"
    mv "$tmp" "$settings"
    echo "basedpyright configFilePath -> $target"
    echo "(Zed will reload settings.json automatically; restart the LSP if it doesn't pick up.)"

# Workspace operations. Subcommands: `clean [--dry]`.
ws CMD *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ CMD }}" in
        clean)
            bash "{{ justfile_directory() }}/scripts/clean-workspace.sh" {{ ARGS }}
            ;;
        *)
            echo "error: unknown ws subcommand: {{ CMD }}" >&2
            echo "available: clean" >&2
            exit 2
            ;;
    esac
