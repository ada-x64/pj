#!/usr/bin/env bash
# ------------------------------------------
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# wt.sh — worktree management for a pj-managed multi-repo workspace.
#
# Manages git worktrees and `active` symlinks across the primary repos
# (bare + worktree layout). Each primary repo has an `active` symlink that
# points to whichever worktree (branch) is currently in use by the project
# (e.g. by a Cargo workspace). Switching the active branch is a symlink
# repoint — no top-level config edits needed.
#
# Env (set by the workspace root .envrc / direnv):
#   PROJECT_ROOT    — workspace root containing the primary repo dirs
#   PRIMARY_REPOS   — whitespace-separated list of primary repo names
#
# Usage:
#   wt.sh add    [--no-switch] <repo> <branch> — create worktree (and switch active)
#   wt.sh switch <repo> <wt>                   — switch active to an existing worktree
#   wt.sh rm     <repo> <branch>               — remove worktree (refuses reserved names)
#   wt.sh ls     [repo]                        — list worktrees
#   wt.sh status                               — show active symlink targets

set -euo pipefail

: "${PROJECT_ROOT:?PROJECT_ROOT not set — run \`direnv allow\` in the workspace root}"
: "${PRIMARY_REPOS:?PRIMARY_REPOS not set — run \`direnv allow\` in the workspace root}"

ROOT="$PROJECT_ROOT"
# shellcheck disable=SC2206
PRIMARY_REPOS_ARR=($PRIMARY_REPOS)
RESERVED_BRANCHES=(main active)

# ── helpers ──────────────────────────────────────────────────────────

usage() {
	cat <<-EOF
		Usage: wt.sh <command> [args]

		Commands:
		  add    [--no-switch] <repo> <branch>
		                           Create worktree and switch active symlink
		                           (branch is created from current active HEAD
		                           if it doesn't exist yet; --no-switch creates
		                           the worktree without repointing active)
		  switch <repo> <wt>       Switch active symlink to an existing worktree
		  rm     <repo> <branch>   Remove worktree (refuses main/active)
		  ls     [repo]            List worktrees (all repos if none specified)
		  status                   Show active symlink targets
	EOF
	exit 1
}

validate_repo() {
	local repo="$1"
	for r in "${PRIMARY_REPOS_ARR[@]}"; do
		if [[ "$r" == "$repo" ]]; then
			return 0
		fi
	done
	echo "error: unknown repo '$repo'"
	echo "valid repos: ${PRIMARY_REPOS_ARR[*]}"
	exit 1
}

is_reserved_branch() {
	local branch="$1"
	for r in "${RESERVED_BRANCHES[@]}"; do
		if [[ "$r" == "$branch" ]]; then
			return 0
		fi
	done
	return 1
}

# Fetch the repo and warn if a branch is behind its upstream.
# Usage: fetch_and_warn <repo_dir> <branch>
# Non-fatal — always returns 0. Prints a warning if behind.
fetch_and_warn() {
	local repo_dir="$1"
	local branch="$2"

	echo "Fetching $repo_dir..."
	if ! git -C "$repo_dir" fetch --quiet 2>/dev/null; then
		echo "⚠  fetch failed (offline?), skipping staleness check"
		return 0
	fi

	local upstream
	upstream="$(git -C "$repo_dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null || true)"
	if [[ -z "$upstream" ]]; then
		return 0
	fi

	local local_ref
	local_ref="$(git -C "$repo_dir" rev-parse --verify "$branch" 2>/dev/null || true)"
	if [[ -z "$local_ref" ]]; then
		return 0
	fi

	local behind
	behind="$(git -C "$repo_dir" rev-list --count "$local_ref".."$upstream")"
	if [[ "$behind" -gt 0 ]]; then
		echo "⚠  $branch is $behind commit(s) behind origin/$branch"
	fi
}

# ── commands ─────────────────────────────────────────────────────────

cmd_add() {
	local no_switch=false
	local args=()
	for arg in "$@"; do
		case "$arg" in
		--no-switch) no_switch=true ;;
		*) args+=("$arg") ;;
		esac
	done

	if [[ ${#args[@]} -lt 2 ]]; then
		echo "Usage: wt.sh add [--no-switch] <repo> <branch>"
		exit 1
	fi

	local repo="${args[0]}"
	local branch="${args[1]}"
	validate_repo "$repo"

	if is_reserved_branch "$branch"; then
		echo "error: '$branch' is a reserved name and cannot be used as a worktree branch"
		exit 1
	fi

	local repo_dir="$ROOT/$repo"

	fetch_and_warn "$repo_dir" "$branch"

	if [[ "$no_switch" == false ]]; then
		local current_target
		current_target="$(readlink "$repo_dir/active")"
		if [[ "$current_target" == "$branch" ]]; then
			echo "✓ $repo/active already points to '$branch'"
			return 0
		fi
	fi

	if ! git -C "$repo_dir" rev-parse --verify "$branch" &>/dev/null; then
		local base
		base="$(readlink "$repo_dir/active")"
		echo "Creating branch '$branch' from '$base' HEAD..."
		git -C "$repo_dir/$base" branch "$branch"
	fi

	if [[ ! -d "$repo_dir/$branch" ]] || [[ -L "$repo_dir/$branch" ]]; then
		echo "Creating worktree '$repo/$branch'..."
		git -C "$repo_dir" worktree add "$branch" "$branch"
	else
		echo "✓ $repo/$branch worktree already exists"
	fi

	if [[ "$no_switch" == true ]]; then
		echo "✓ $repo/$branch ready (active unchanged)"
	else
		ln -sfn "$branch" "$repo_dir/active"
		echo "✓ $repo/active → $branch"
	fi
}

cmd_switch() {
	if [[ $# -lt 2 ]]; then
		echo "Usage: wt.sh switch <repo> <worktree>"
		exit 1
	fi

	local repo="$1"
	local wt="$2"
	validate_repo "$repo"

	local repo_dir="$ROOT/$repo"

	fetch_and_warn "$repo_dir" "$wt"

	local current_target
	current_target="$(readlink "$repo_dir/active")"
	if [[ "$current_target" == "$wt" ]]; then
		echo "✓ $repo/active already points to '$wt'"
		return 0
	fi

	if [[ ! -d "$repo_dir/$wt" ]] || [[ -L "$repo_dir/$wt" ]]; then
		echo "error: worktree '$repo/$wt' does not exist"
		echo "Use 'wt.sh add $repo $wt' to create it first."
		exit 1
	fi

	ln -sfn "$wt" "$repo_dir/active"
	echo "✓ $repo/active → $wt (was $current_target)"
}

cmd_rm() {
	if [[ $# -lt 2 ]]; then
		echo "Usage: wt.sh rm <repo> <branch>"
		exit 1
	fi

	local repo="$1"
	local branch="$2"
	validate_repo "$repo"

	if is_reserved_branch "$branch"; then
		echo "error: refusing to remove reserved branch '$branch'"
		exit 1
	fi

	local repo_dir="$ROOT/$repo"

	fetch_and_warn "$repo_dir" "$branch"

	local active_target
	active_target="$(readlink "$repo_dir/active")"
	local needs_restore=false
	if [[ "$active_target" == "$branch" ]]; then
		echo "Switching $repo/active back to main..."
		ln -sfn main "$repo_dir/active"
		echo "✓ $repo/active → main"
		needs_restore=true
	fi

	if [[ -d "$repo_dir/$branch" ]]; then
		if ! git -C "$repo_dir" worktree remove "$branch"; then
			if [[ "$needs_restore" == true ]]; then
				ln -sfn "$branch" "$repo_dir/active"
				echo "✗ restored $repo/active → $branch (worktree removal failed)"
			fi
			echo "error: failed to remove worktree (dirty tree?). Use 'git worktree remove --force' manually."
			exit 1
		fi
		echo "✓ $repo/$branch worktree removed"
	else
		echo "$repo/$branch does not exist"
	fi
}

cmd_ls() {
	local repos=("${PRIMARY_REPOS_ARR[@]}")
	if [[ $# -ge 1 ]]; then
		validate_repo "$1"
		repos=("$1")
	fi

	for repo in "${repos[@]}"; do
		local repo_dir="$ROOT/$repo"
		local active_target
		active_target="$(readlink "$repo_dir/active" 2>/dev/null || echo "?")"

		echo "── $repo (active → $active_target) ──"
		git -C "$repo_dir" worktree list
		echo ""
	done
}

cmd_status() {
	for repo in "${PRIMARY_REPOS_ARR[@]}"; do
		local repo_dir="$ROOT/$repo"
		local active_target
		active_target="$(readlink "$repo_dir/active" 2>/dev/null || echo "NOT SET")"
		echo "$repo/active → $active_target"
	done
}

# ── main ─────────────────────────────────────────────────────────────

case "${1:-}" in
add)
	shift
	cmd_add "$@"
	;;
switch)
	shift
	cmd_switch "$@"
	;;
rm)
	shift
	cmd_rm "$@"
	;;
ls)
	shift
	cmd_ls "$@"
	;;
status)
	shift
	cmd_status "$@"
	;;
*) usage ;;
esac
