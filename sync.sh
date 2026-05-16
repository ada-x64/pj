#!/bin/bash
set -euo pipefail

# Setup
BASE_DIR=${BASE_DIR:-$HOME/repos}
CONFIG_DIR=${CONFIG_DIR:-$HOME/repos/nanvix/.config}
PRIMARY_REPOS=(nanvix/zutils nanvix/workflows nanvix/nanvix nanvix/nanvix-python)
DRY=true
CLOBBER=false

for arg in "$@"; do
    case "$arg" in
        -x|--execute) DRY=false ;;
        --clobber)    CLOBBER=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Update repo list
gh api /repos/nanvix/workflows/contents/consumer-repos.json --jq .download_url | xargs curl -L > "$CONFIG_DIR/consumer-repos.json"
mapfile -t ALL_REPOS < <(jq -r '.[]' consumer-repos.json)
ALL_REPOS+=("${PRIMARY_REPOS[@]}")

# Dry run helper
run() {
    if [ "$DRY" = "true" ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# Main loop
function sync_repo() {
    local repo="$1"
    local dir="${BASE_DIR}/${repo}"

    echo -e "\n=== ${repo} ==="

    if [ -d "${dir}" ]; then
        echo "✅ ${dir} exists"
    else
        echo "❌ ${dir} missing"
        run mkdir -p "${dir}"
    fi

    if [ ! -d "${dir}/.bare" ]; then
        echo "❌ .bare missing"
        run git clone --bare "https://github.com/${repo}" "${dir}/.bare"
    else
        echo "✅ .bare exists"
    fi

    echo "ℹ️ syncing .bare"
    run git -C "${dir}/.bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    run git -C "${dir}/.bare" fetch --all --prune
    run bash -c "echo \"gitdir: ./.bare\" > ${dir}/.git"
    run git -C "${dir}/.bare" config worktree.useRelativePaths true
    run git -C "${dir}/.bare" worktree repair

    echo "ℹ️ syncing config files"
    run ln -sf -T "${CONFIG_DIR}/AGENTS.md" "${dir}/AGENTS.md"
    run ln -sf -T "${CONFIG_DIR}/justfile" "${dir}/justfile"
    run bash -c "cp \"${CONFIG_DIR}/pyrightconfig.json\" \"${dir}/pyrightconfig.json\" || true"

    local default_branch=$(gh repo view ${repo} --json defaultBranchRef --jq '.defaultBranchRef.name')
    run bash -c "echo \"${default_branch}\" > ${dir}/.default-branch"

    echo "ℹ️ syncing default branch"
    if [ ! -d "${dir}/${default_branch}" ]; then
        echo "❌ ${dir}/${default_branch} missing"
        run git -C "${dir}/.bare" worktree add "${dir}/${default_branch}" "${default_branch}"
    else
        echo "✅ ${dir}/${default_branch} exists"
    fi

    local status=$(git -C "${dir}/${default_branch}" status --porcelain)
    if [ -n "${status}" ]; then
        if [ "${CLOBBER}" = "true" ]; then
            echo "⚠️ ${dir}/${default_branch} has uncommitted changes. Clobbering..."
        else
            echo "⚠️ ${dir}/${default_branch} has uncommitted changes. Re-run with --clobber to overwrite."
            [ "$DRY" = "false" ] && exit 1
        fi
    else
        echo "✅ ${dir}/${default_branch} clean"
    fi

    run git -C "${dir}/${default_branch}" reset --hard origin/${default_branch}
    run git -C "${dir}/${default_branch}" clean -fd
}

for repo in "${ALL_REPOS[@]}"; do
    sync_repo "${repo}"
done
