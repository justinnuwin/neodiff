#!/bin/bash
# Build a deterministic fixture git repo for the neodiff tests. The repo exercises
# every git status the shell launcher cares about (add / modify / delete / rename)
# plus a working-tree change, a staged change, and -- when the git build allows a
# local submodule -- a changed submodule (a gitlink that parse must skip).
#
# Args:
#   target_dir - directory to create the repo in (created if missing, must be empty)
#
# Layout after the final HEAD commit (vs its parent HEAD~1):
#   A  dir/new.c              added
#   M  dir/mod.c              modified
#   D  del.txt                deleted
#   R  rename_src.txt -> rename_dst.txt
#   (sub                      changed submodule, present only if supported)
# Then, on top of HEAD, working-tree and staged edits to keep.txt so the
# no-arg and --staged diff patterns each have exactly one changed file.
set -eu

target_dir="$1"
mkdir -p "$target_dir"

# Isolated, reproducible git: no user config bleed, no commit signing prompt,
# and file-protocol submodules permitted for the gitlink case.
git_cmd() {
    git -C "$target_dir" \
        -c init.defaultBranch=main \
        -c user.name=neodiff-test -c user.email=test@neodiff \
        -c commit.gpgsign=false \
        -c protocol.file.allow=always \
        "$@"
}

git_cmd init -q

# --- Baseline commit (HEAD~1) ---
printf 'keep\n' > "$target_dir/keep.txt"
printf 'bye\n' > "$target_dir/del.txt"
printf 'rename me\n' > "$target_dir/rename_src.txt"
mkdir -p "$target_dir/dir"
printf 'line1\nline2\n' > "$target_dir/dir/mod.c"
git_cmd add -A
git_cmd commit -q -m baseline

# --- Optional submodule (a gitlink git reports as a directory path) ---
# Needs a submodule with at least one commit; guarded because some git builds
# forbid file-protocol submodules. sub_ok stays 0 if anything fails.
sub_ok=0
sub_repo="$target_dir/../fixture_sub_$$"
sub_git() {
    git -C "$sub_repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}
if git init -q "$sub_repo" 2>/dev/null \
    && sub_git commit -q --allow-empty -m sub-init 2>/dev/null \
    && git_cmd submodule add -q "$sub_repo" sub 2>/dev/null; then
    sub_ok=1
    git_cmd add -A
    git_cmd commit -q -m add-submodule
fi

# --- HEAD commit: add / modify / delete / rename ---
printf 'added\n' > "$target_dir/dir/new.c"
printf 'line1\nchanged\nline3\n' > "$target_dir/dir/mod.c"
rm "$target_dir/del.txt"
git_cmd mv rename_src.txt rename_dst.txt
# Advance the submodule's own HEAD so the superproject records a new gitlink,
# making `sub` appear as a change in this commit's diff (parse must skip it).
if [ "$sub_ok" = 1 ]; then
    git -C "$target_dir/sub" -c user.name=t -c user.email=t@t \
        -c commit.gpgsign=false commit -q --allow-empty -m sub-bump 2>/dev/null || true
fi
git_cmd add -A
git_cmd commit -q -m changes

# --- On top of HEAD: one staged and one unstaged edit to keep.txt ---
# (kept separate so --staged sees index-vs-HEAD and no-args sees working-vs-index).
printf 'keep\nstaged line\n' > "$target_dir/keep.txt"
git_cmd add keep.txt
printf 'keep\nstaged line\nworking line\n' > "$target_dir/keep.txt"
