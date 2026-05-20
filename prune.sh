#!/bin/bash
set -uo pipefail

# Setup
BASE_DIR=${BASE_DIR:-$HOME/repos}
CONFIG_DIR=${CONFIG_DIR:-$HOME/repos/nanvix/.config}
PRIMARY_REPOS=(nanvix/zutils nanvix/workflows nanvix/nanvix nanvix/nanvix-python)
VALID_PREFIXES=(feat fix doc tests release)
DEFAULT_REMOTE=${DEFAULT_REMOTE:-origin}
DRY=true

for arg in "$@"; do
    case "$arg" in
        -x|--execute) DRY=false ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Dry run helper
run() {
    if [ "$DRY" = "true" ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# Build the list of repos to walk (same set sync.sh manages).
# Refresh is handled by `just _refresh-downstreams` (run via `just prune`).
if [ ! -f "${CONFIG_DIR}/consumer-repos.json" ]; then
    echo "consumer-repos.json missing; run 'just _refresh-downstreams' or 'just prune' first" >&2
    exit 1
fi
mapfile -t ALL_REPOS < <(jq -r '.[]' "${CONFIG_DIR}/consumer-repos.json")
ALL_REPOS+=("${PRIMARY_REPOS[@]}")

prune_repo() {
    local repo="$1"
    local dir="${BASE_DIR}/${repo}"

    echo -e "\n=== ${repo} ==="

    if [ ! -d "${dir}/.bare" ]; then
        echo "⚠️  ${dir}/.bare missing. Skipping (run sync first)."
        return
    fi

    if [ ! -f "${dir}/.default-branch" ]; then
        echo "⚠️  ${dir}/.default-branch missing. Skipping."
        return
    fi
    local default_branch
    default_branch=$(cat "${dir}/.default-branch")

    echo "ℹ️  fetching ${repo}"
    run git -C "${dir}/.bare" fetch --all --prune

    if [ ! -d "${dir}/${default_branch}" ]; then
        echo "⚠️  default worktree ${dir}/${default_branch} missing. Skipping."
        return
    fi

    echo "ℹ️  fast-forwarding ${default_branch}"
    if ! run git -C "${dir}/${default_branch}" pull "${DEFAULT_REMOTE}" "${default_branch}" --ff-only; then
        echo "❌ Failed to fast-forward ${default_branch} in ${repo}. Skipping."
        return
    fi

    # Retarget 'active' symlink to the default branch worktree.
    if [ -L "${dir}/active" ] || [ ! -e "${dir}/active" ]; then
        run ln -sfn "${default_branch}" "${dir}/active"
    fi

    # Walk each valid-prefix directory looking for worktrees to prune.
    for prefix in "${VALID_PREFIXES[@]}"; do
        local pdir="${dir}/${prefix}"
        [ -d "${pdir}" ] || continue

        for branch_path in "${pdir}"/*/; do
            [ -d "${branch_path}" ] || continue
            branch_path="${branch_path%/}"

            local branch
            if ! branch=$(git -C "${branch_path}" symbolic-ref --short HEAD 2>/dev/null); then
                echo "❌ Could not determine branch name for ${branch_path}. Skipping."
                continue
            fi

            local status
            status=$(git -C "${branch_path}" status --porcelain 2>/dev/null || true)
            if [ -n "${status}" ]; then
                echo "⚠️  ${branch} is not clean. Skipping."
                continue
            fi

            # Synced: no local commits missing from remote tracking branch.
            local ahead
            ahead=$(git -C "${branch_path}" rev-list "${branch}" "^${DEFAULT_REMOTE}/${branch}" 2>/dev/null || true)
            if [ -n "${ahead}" ]; then
                echo "⚠️  ${branch} is not synced with ${DEFAULT_REMOTE}/${branch}. Skipping."
                continue
            fi
            echo "ℹ️  ${branch} is synced"

            # Merged: branch tip is an ancestor of origin/default.
            if git -C "${branch_path}" merge-base --is-ancestor "${branch}" "${DEFAULT_REMOTE}/${default_branch}"; then
                echo "✂️  Removing ${branch}"
                if [ "$DRY" = "false" ]; then
                    rm -rf "${branch_path}"
                else
                    echo "[dry-run] rm -rf ${branch_path}"
                fi
                run git -C "${dir}/.bare" branch --delete "${branch}"
                run git -C "${dir}/.bare" worktree prune
            else
                echo "⚠️  ${branch_path} not yet merged into ${DEFAULT_REMOTE}/${default_branch}. Skipping."
            fi
        done
    done
}

for repo in "${ALL_REPOS[@]}"; do
    prune_repo "${repo}"
done
