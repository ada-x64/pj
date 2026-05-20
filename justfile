BASE_DIR := env("HOME") + "/repos"
CONFIG_DIR := BASE_DIR + "/nanvix/.config"

_default:
    just --list

# Run ./z setup in the active directory.
setup:
    cd active && ./z setup --with-docker nanvix/toolchain:latest-minimal

# Run ./z build in the active directory.
build:
    cd active && ./z build

# Run ./z test in the active directory.
test:
    cd active && ./z test

# Run ./z release in the active directory.
release:
    cd active && ./z release

# Run ./z clean in the active directory.
clean:
    cd active && ./z clean

# Run ./z clean in the active directory.
distclean:
    cd active && ./z clean && ./z distclean

# Change where 'active' points to.
target *args:
    #!/bin/bash
    "{{ CONFIG_DIR }}/wt.sh" target {{ args }}

# Create a new worktree.
add *args:
    #!/bin/bash
    "{{ CONFIG_DIR }}/wt.sh" add {{ args }}

# Get the default branch name from GitHub and persist it to disk.
_get-default:
    gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' | tee .default-branch

# Set NANVIX_SKIP_REFRESH=1 to bypass (offline use).
refresh-downstreams:
    #!/bin/bash
    set -euo pipefail
    if [ "${NANVIX_SKIP_REFRESH:-0}" = "1" ]; then
        echo "ℹ️  NANVIX_SKIP_REFRESH=1; using existing consumer-repos.json"
        exit 0
    fi
    echo "ℹ️  refreshing consumer-repos.json from nanvix/workflows"
    url=$(gh api /repos/nanvix/workflows/contents/consumer-repos.json --jq .download_url)
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$url" -o "$tmp"
    jq empty "$tmp"
    mv "$tmp" "$HOME/repos/nanvix/.config/consumer-repos.json"
    trap - EXIT

# Refresh downstreams, create any missing. Dry-run by default.
sync *args: refresh-downstreams
    "{{ CONFIG_DIR }}/sync.sh" {{ args }}

# Prune merged worktrees. Dry-run by default.
prune *args:
    "{{ CONFIG_DIR }}.sh" {{ args }}

import? "local.just"
