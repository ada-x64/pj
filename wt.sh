#!/bin/bash
RECIPE="$1"; shift
LOOP=""
NAME=""
DRY=""
FN=""
USAGE="Usage:\njust ${RECIPE} [--all-downstreams] [--dry] <branch-name>"
BASE_DIR="$HOME/repos"
CONFIG_DIR="$BASE_DIR/nanvix/.config"

target() {
    local name="$NAME"
    if [ "${name}" == "default" ]; then
        if [ ! -f .default-branch ]; then
            just _get-default
        fi
        name="$(cat .default-branch)"
    fi
    if [ ! -d "${name}" ]; then
        echo "Directory ${name} does not exist"
        exit 1
    fi
    if [ -n "$DRY" ]; then
        echo "[dry] Would create symlink: ln -s ${name} active"
        if [[ -n "$LOOP" ]]; then
            echo "[dry] Would run: (cd ${name} && ./z setup --with-docker nanvix/toolchain:latest-minimal)"
        fi
        if [ -e "target-hook.sh" ]; then
            echo "[dry] Would run: bash target-hook.sh"
        fi
        return
    fi
    ln -s "${name}" -T active -f
    ls active -l
    if [[ -n "$LOOP" ]]; then
        ( cd "$name" && ./z setup --with-docker nanvix/toolchain:latest-minimal )
    fi
    if [ -e "target-hook.sh" ]; then
        bash target-hook.sh
    fi
}

add() {
    if [[ ! ${NAME} =~ ^(fix|feat|doc|tests|release)/ ]]; then
        echo "Invalid branch name: ${NAME}"
        echo "Valid branch names are: fix/*, feat/*, doc/*, tests/*, release/*"
        exit 1
    fi
    if [ ! -f .default-branch ]; then
        just _get-default
    fi
    cmd="git worktree add ${NAME} -b ${NAME} origin/$(cat .default-branch)"
    if [ -n "$DRY" ]; then
        echo "[dry] Would create worktree: ${cmd}"
        return
    fi
    git fetch
    $cmd
}


if [ ${#@} -eq 0 ]; then
    echo -e "$USAGE"
    exit 1
fi

for a in "$@"; do
    case "$a" in
        --all-downstreams)
            LOOP=1
            ;;
        --dry)
            DRY=1
            ;;
        -*)
            echo "Invalid argument: $a"
            echo -e "$USAGE"
            exit 1
            ;;
        *)
            if [ -n "$NAME" ]; then
                echo "This script only accepts one name."
                echo -e "$USAGE"
                exit 1
            fi
            NAME="$a"
            ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Must specify a name."
    echo -e "$USAGE"
    exit 1
fi


case "$RECIPE" in
    target)
        FN=target
        ;;
    add)
        FN=add
        ;;
    *)
        echo "Recipe '$RECIPE' is not supported."
        exit 1
        ;;
esac

if [[ -n "$LOOP" ]]; then
    while IFS= read -r repo; do
        echo "=== $repo ==="
        ( cd "$BASE_DIR/$repo" && $FN )
    done < <(jq -r '.[]' "$CONFIG_DIR/consumer-repos.json")
else
    $FN
fi
