#!/usr/bin/env bash
# Workspace cleanup: enforces primary-repo + default-branch invariants.
#
# Reads PRIMARY_REPOS (whitespace-separated) and GH_TOKEN from the env
# (typically sourced from $PROJECT_ROOT/.envrc).
#
# Per primary repo:
#   - Ensures bare+worktree layout at <root>/<name>/.bare. If absent,
#     clones https://github.com/nanvix/<name> as a bare repo there.
#   - Bumps core.repositoryformatversion to 1 and sets
#     extensions.relativeWorktrees=true.
#   - Discovers default branch via `gh repo view <owner/name>`.
#   - Resets bare HEAD to the default branch.
#   - Fetches all remotes (--prune).
#   - Removes worktrees whose branch is merged into origin/<default>,
#     except the worktree on the default branch itself (always kept).
#   - Removes orphan bare-side registrations (no local checkout).
#   - Creates the default-branch worktree at <root>/<name>/<default> if missing.
#   - Rewrites every worktree's gitdir (both sides) to relative paths.
#   - Runs `git worktree prune`.
#
# Top-level dirs in <root> that are not in PRIMARY_REPOS are deleted outright.
#
# Usage: clean-workspace.sh [--dry]
#   default: apply changes
#   --dry:   preview without changes

set -euo pipefail

MODE="apply"
for arg in "$@"; do
  case "$arg" in
    --dry|-n) MODE="dry" ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "error: unknown arg: $arg" >&2; echo "usage: $0 [--dry]" >&2; exit 2 ;;
  esac
done

ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
OWNER="${PRIMARY_OWNER:-nanvix}"

: "${PRIMARY_REPOS:?PRIMARY_REPOS is unset; source .envrc first}"
command -v gh >/dev/null || { echo "ERROR: gh CLI not found" >&2; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not found" >&2; exit 1; }

# Defang dubious-ownership errors when running as a different uid than file owner.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

run() {
  if [[ "$MODE" == "apply" ]]; then "$@"; else echo "DRY: $*"; fi
}

# --- Build keep-set from PRIMARY_REPOS ---
declare -A KEEP=()
for n in $PRIMARY_REPOS; do KEEP[$n]=1; done

# --- Phase 0: delete non-primary top-level dirs ---
echo "=== Phase 0: prune non-primary top-level dirs ==="
shopt -s nullglob
for d in "$ROOT"/*/; do
  name=$(basename "$d")
  [[ -v KEEP[$name] ]] && continue
  echo "  not primary: $name"
  run rm -rf "$d"
done
shopt -u nullglob

# --- Phase 1: per-repo invariants ---
for name in "${!KEEP[@]}"; do
  echo
  echo "=== $name ==="
  base="$ROOT/$name"
  bare="$base/.bare"
  slug="$OWNER/$name"

  # Bootstrap if missing
  if [[ ! -d "$bare" ]]; then
    echo "  no .bare — bootstrapping from https://github.com/$slug"
    run mkdir -p "$base"
    run git clone --bare "https://github.com/$slug" "$bare"
    if [[ "$MODE" == "apply" ]]; then
      printf 'gitdir: ./.bare\n' > "$base/.git"
    else
      echo "DRY: write $base/.git -> 'gitdir: ./.bare'"
    fi
  fi

  # Skip remaining steps in dry mode if bare didn't exist (gh would fail without it)
  if [[ ! -d "$bare" ]]; then
    echo "  (dry: would set up $bare and continue)"
    continue
  fi

  # Discover default branch via gh
  default=$(gh repo view "$slug" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) \
    || { echo "  ERROR: gh failed for $slug; skipping"; continue; }
  [[ -n "$default" ]] || { echo "  ERROR: empty default branch for $slug; skipping"; continue; }
  echo "  default branch: $default"

  # Config: format version + extension (idempotent)
  if [[ "$MODE" == "apply" ]]; then
    sed -i 's/repositoryformatversion = 0/repositoryformatversion = 1/' "$bare/config"
    if ! grep -q '\[extensions\]' "$bare/config"; then
      printf '[extensions]\n\trelativeWorktrees = true\n' >> "$bare/config"
    elif ! grep -q 'relativeWorktrees' "$bare/config"; then
      sed -i '/\[extensions\]/a\\trelativeWorktrees = true' "$bare/config"
    fi
  else
    echo "DRY: ensure repositoryformatversion=1 and extensions.relativeWorktrees=true in $bare/config"
  fi

  # HEAD -> default
  run git -C "$bare" symbolic-ref HEAD "refs/heads/$default"

  # Fetch
  run git -C "$bare" fetch --all --prune --quiet

  # Iterate registered worktrees
  remote_default="origin/$default"
  for wtd in "$bare"/worktrees/*/; do
    [[ -d "$wtd" ]] || continue
    wname=$(basename "$wtd")
    head=$(cat "$wtd/HEAD" 2>/dev/null || echo "")
    branch=${head#ref: refs/heads/}
    gd=$(cat "$wtd/gitdir" 2>/dev/null || echo "")

    # Resolve current worktree path from gitdir file
    case "$gd" in
      /*)  wt_path=${gd%/.git} ;;
      *)   wt_path=$(cd "$wtd" 2>/dev/null && cd "$(dirname "$gd")" 2>/dev/null && pwd || echo "") ;;
    esac

    # Default-branch worktree: keep
    if [[ "$branch" == "$default" ]]; then
      echo "  keep [$wname] $branch (default)"
      continue
    fi

    # Orphan registration (no local checkout)
    if [[ -z "$wt_path" || ! -e "$wt_path/.git" ]]; then
      echo "  orphan reg [$wname] $branch -> drop"
      run rm -rf "$wtd"
      continue
    fi

    # Merged into origin/default -> delete
    if git -C "$bare" merge-base --is-ancestor "$branch" "$remote_default" 2>/dev/null; then
      echo "  merged [$wname] $branch -> remove $wt_path"
      run rm -rf "$wt_path" "$wtd"
      parent=$(dirname "$wt_path")
      if [[ "$parent" != "$base" && -d "$parent" && -z "$(ls -A "$parent" 2>/dev/null)" ]]; then
        run rmdir "$parent"
      fi
    else
      echo "  keep [$wname] $branch (unmerged)"
    fi
  done

  # Ensure default-branch worktree exists at $base/$default
  if [[ ! -e "$base/$default/.git" ]]; then
    echo "  add default worktree at $base/$default"
    run git -C "$bare" worktree add "$base/$default" "$default"
  fi

  # Prune stale registrations
  run git -C "$bare" worktree prune

  # Relativize all gitdirs (both sides) for surviving worktrees
  if [[ "$MODE" == "apply" ]]; then
    for wtd in "$bare"/worktrees/*/; do
      [[ -d "$wtd" ]] || continue
      wname=$(basename "$wtd")
      gd=$(cat "$wtd/gitdir")
      case "$gd" in
        /*)  wt_path=${gd%/.git} ;;
        *)   wt_path=$(cd "$wtd" && cd "$(dirname "$gd")" && pwd) ;;
      esac
      rel_wtpath=${wt_path#"$base/"}
      depth=$(awk -F/ '{print NF}' <<< "$rel_wtpath")
      up=""; for ((i=0;i<depth;i++)); do up+="../"; done
      printf 'gitdir: %s.bare/worktrees/%s\n' "$up" "$wname" > "$wt_path/.git"
      printf '../../../%s/.git\n' "$rel_wtpath" > "$wtd/gitdir"
    done
  else
    echo "DRY: relativize gitdirs for all worktrees under $bare"
  fi
done

echo
if [[ "$MODE" == "dry" ]]; then
  echo "=== done (dry — no changes made; re-run without --dry to apply) ==="
else
  echo "=== done ==="
fi
