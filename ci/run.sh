#!/bin/sh
# Single entry point for neodiff CI. On the host it builds the CI image (on first
# use) and re-runs itself inside a container; inside the container it runs every
# check and aggregates their exit codes:
#
#   1. shellcheck   - shell scripts
#   2. vint         - Vimscript (plugin/, autoload/)
#   3. functional   - headless plugin tests on vim 8.2 and neovim 0.12.4
#   4. shell        - shell string-builder / parser assertions
#   5. screendump   - golden visual dumps (vim + nvim inner render)
#
# NEODIFF_UPDATE=1 regenerates the committed screen-dump goldens instead of
# asserting against them. Force an image rebuild with: docker build -t neodiff-ci ci
set -eu

image="neodiff-ci"

unset CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

# ------------------------------------------------------------------------------
# Inside the container: run all checks.
# ------------------------------------------------------------------------------
if [ -n "${NEODIFF_IN_CONTAINER:-}" ]; then
    cd "$repo_root"
    overall=0

    # Run a labelled step (a function name); record but do not abort on failure.
    step() {
        label=$1
        shift
        printf '\n=== %s ===\n' "$label"
        if "$@"; then
            printf 'OK: %s\n' "$label"
        else
            printf 'FAIL: %s (exit %d)\n' "$label" "$?"
            overall=1
        fi
    }

    lint_shell() {
        # Prefer git's list, but fall back to find: inside the container this is a
        # submodule whose .git file points outside the mount, so git is unusable.
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            scripts=$(git ls-files --cached --others --exclude-standard '*.sh')
        else
            scripts=$(find . -name '*.sh' -type f | sed 's|^\./||')
        fi
        if [ -z "$scripts" ]; then
            echo 'no shell scripts found'
            return 0
        fi
        echo "$scripts" | sed 's/^/  /'
        # One shellcheck over all scripts; word-splitting is intended here.
        # shellcheck disable=SC2086
        shellcheck $scripts
    }

    lint_vim() {
        vint plugin/ autoload/
    }

    test_functional_vim() {
        vim -Nu ci/vimrc -es -S ci/run_functional.vim
    }

    test_functional_nvim() {
        nvim -Nu ci/vimrc --headless -S ci/run_functional.vim
    }

    test_shell() {
        bash ci/test_neodiff.sh
    }

    # Golden screen dumps: build the fixture at a fixed path (so nothing on
    # screen varies run to run) and drive the outer Vim under a pty via `script`,
    # since term_start needs a terminal.
    test_screendump() {
        rm -rf /tmp/nd-fixture
        if ! bash ci/mkrepo.sh /tmp/nd-fixture >/dev/null 2>&1; then
            echo 'fixture repo build failed'
            return 1
        fi
        if NEODIFF_FIXTURE=/tmp/nd-fixture NEODIFF_UPDATE="${NEODIFF_UPDATE:-}" \
            script -q -e -c 'vim -Nu ci/vimrc -S ci/screendump.vim' /dev/null; then
            return 0
        fi
        rc=$?
        if [ -s ci/dumps/last_result.txt ]; then
            cat ci/dumps/last_result.txt
        fi
        return "$rc"
    }

    step 'shellcheck (shell)' lint_shell
    step 'vint (vimscript)' lint_vim
    step 'functional (vim 8.2)' test_functional_vim
    step 'functional (nvim 0.12.4)' test_functional_nvim
    step 'shell assertions' test_shell
    step 'screendump goldens' test_screendump

    printf '\n'
    if [ "$overall" -eq 0 ]; then
        echo 'ALL CHECKS PASSED'
    else
        echo 'SOME CHECKS FAILED'
    fi
    exit "$overall"
fi

# ------------------------------------------------------------------------------
# On the host: ensure the image, then run this script inside the container.
# ------------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo 'error: docker is required but was not found in PATH' >&2
    exit 1
fi

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Building $image image..."
    docker build -t "$image" "$script_dir"
fi

# --user matches the host uid so files written under the mount (the goldens on
# NEODIFF_UPDATE) are owned by the caller, not root. HOME is set because that
# user has no /etc/passwd entry.
exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e NEODIFF_IN_CONTAINER=1 \
    -e HOME=/tmp \
    -e NEODIFF_UPDATE="${NEODIFF_UPDATE:-}" \
    -v "$repo_root:/work" \
    -w /work \
    "$image" sh ci/run.sh
