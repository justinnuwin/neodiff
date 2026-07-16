#!/bin/sh
# Lint every shell script in the repo with shellcheck. Builds the container on
# first use. Exits zero if shellcheck finds no issues.
set -eu

image="neodiff-shellcheck"

# Repo root is the parent of this script's directory (ci/). Clear CDPATH so cd
# cannot resolve a same-named sibling or print the target path.
unset CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is required but was not found in PATH" >&2
    exit 1
fi

# Build the image if it does not exist yet. Force a rebuild any time with:
#   docker build -t neodiff-shellcheck ci
if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Building $image image..."
    docker build -t "$image" "$script_dir"
fi

# Collect the shell scripts to lint: tracked plus new (untracked) *.sh, minus
# anything gitignored, so a not-yet-committed script is still checked. Fall back
# to a find when this is not a git checkout. Paths stay repo-relative so they
# line up with the mounted /work directory inside the container.
cd "$repo_root"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    scripts=$(git ls-files --cached --others --exclude-standard '*.sh')
else
    scripts=$(find . -name '*.sh' -type f | sed 's|^\./||')
fi

if [ -z "$scripts" ]; then
    echo "No shell scripts found to lint."
    exit 0
fi

echo "Linting:"
echo "$scripts" | sed 's/^/  /'

# One shellcheck invocation over all scripts. Word-splitting is intentional here
# (one argument per script), so the usual quoting lint is disabled for this line.
# shellcheck disable=SC2086
docker run --rm -v "$repo_root:/work" -w /work "$image" $scripts

echo "shellcheck passed."
