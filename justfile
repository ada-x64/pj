BASE_DIR := "$HOME/repos"
CONFIG_DIR := "$BASE_DIR/nanvix/.config"

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
target dir:
    #!/bin/bash
    dir={{dir}}
    if [ "${dir}" == "default" ]; then
        if [ ! -f .default-branch ]; then
            just _get-default
        fi
        dir="$(cat .default-branch)"
    fi
    if [ ! -d "${dir}" ]; then
        echo "Directory ${dir} does not exist"
        exit 1
    fi
    ln -s "${dir}" -T active -f
    ls active -l

# Create a new worktree.
add name:
    #!/bin/bash
    if [[ ! {{name}} =~ ^fix|feat|doc|tests ]]; then
        echo "Invalid branch name: {{name}}"
        echo "Valid branch names are: fix/*, feat/*, doc/*, tests/*"
        exit 1
    fi
    if [ ! -f .default-branch ]; then
        just _get-default
        exit 1
    fi
    git fetch
    git worktree add {{name}} -b {{name}} "origin/$(cat .default-branch)"

# Get the default branch name from GitHub and persist it to disk.
_get-default:
    gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' | tee .default-branch

# Get the latest consumer repos from nanvix/workflows
_refresh-downstreams:
    #!/bin/bash

# All needed repos NOT included in consumer-repos.json

# Refresh downstream consumers and create any missing metarepo directories.
# Will fixup any existing repos.
# Dry-run by default. Pass -x/--execute to run, --clobber to overwrite dirty worktrees.
sync *args:
    ~/repos/nanvix/.config/sync.sh {{args}}
