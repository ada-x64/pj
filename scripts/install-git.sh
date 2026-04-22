#!/usr/bin/env bash
# install-git.sh — ensure git >= 2.48 (required for extensions.relativeWorktrees).
#
# On Ubuntu/Debian, installs from ppa:git-core/ppa.
# Idempotent: skips work if git is already new enough.
#
# Usage:
#   .config/scripts/install-git.sh            # install/upgrade if needed
#   .config/scripts/install-git.sh --check    # exit 0 if OK, non-zero otherwise

set -euo pipefail

MIN_MAJOR=2
MIN_MINOR=48

CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  "") ;;
  *) echo "error: unknown arg: $1" >&2; exit 2 ;;
esac

current_version() {
  command -v git >/dev/null || { echo "0.0.0"; return; }
  git --version | awk '{print $3}'
}

version_ok() {
  local v=$1
  local major minor
  IFS=. read -r major minor _ <<< "$v"
  (( major > MIN_MAJOR )) && return 0
  (( major == MIN_MAJOR && minor >= MIN_MINOR )) && return 0
  return 1
}

cur=$(current_version)
echo "current git: $cur (need >= ${MIN_MAJOR}.${MIN_MINOR})"

if version_ok "$cur"; then
  echo "OK — no action needed"
  exit 0
fi

if (( CHECK_ONLY )); then
  echo "FAIL — git is too old"
  exit 1
fi

# --- install path ---
if [[ ! -r /etc/os-release ]]; then
  echo "error: /etc/os-release missing; cannot detect distro" >&2
  exit 1
fi
. /etc/os-release

case "$ID" in
  ubuntu|debian)
    SUDO=""
    if [[ $EUID -ne 0 ]]; then
      command -v sudo >/dev/null || { echo "error: need root or sudo" >&2; exit 1; }
      SUDO="sudo"
    fi
    echo "==> installing software-properties-common (for add-apt-repository)"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y software-properties-common
    echo "==> adding ppa:git-core/ppa"
    $SUDO add-apt-repository -y ppa:git-core/ppa
    $SUDO apt-get update -qq
    echo "==> installing/upgrading git"
    $SUDO apt-get install -y git
    ;;
  *)
    echo "error: unsupported distro '$ID'" >&2
    echo "       install git >= ${MIN_MAJOR}.${MIN_MINOR} manually from your package manager" >&2
    exit 1
    ;;
esac

new=$(current_version)
echo "==> git is now: $new"
if ! version_ok "$new"; then
  echo "error: install completed but git is still $new (< ${MIN_MAJOR}.${MIN_MINOR})" >&2
  exit 1
fi
echo "OK"
