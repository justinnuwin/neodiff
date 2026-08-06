#!/usr/bin/env bash
# Assertions for the shell half of neodiff (shell/neodiff.sh): the Vimscript
# string builders and the git-diff parser. Sources the module and inspects the
# strings/arrays it produces for each status and argument pattern. A fixture repo
# from ci/mkrepo.sh drives the parser. Exits non-zero on any failed assertion.
#
# No `set -u`/`set -e`: the module is written for an ordinary interactive shell
# (it reads optional positionals and env vars), and failures are tracked
# explicitly via fail_count instead of aborting.
#
# _neodiff_parse_changes communicates through caller-scope globals -- it reads
# $toplevel and writes $_ndf_args / $_ndf_entries -- which shellcheck cannot
# track across the `source` boundary.
# shellcheck disable=SC2034,SC2154

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

# Pin copy detection off so a caller's environment cannot change what the parser
# reports.
export NEODIFF_FIND_COPIES=""

# shellcheck source=/dev/null
source "$repo_root/shell/neodiff.sh"

fail_count=0
pass_count=0

# Compare two strings for exact equality.
# Args: label expected actual
assert_eq() {
    if [ "$2" = "$3" ]; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
    fi
}

# Assert the haystack contains the needle substring.
# Args: label needle haystack
assert_contains() {
    if case "$3" in *"$2"*) true ;; *) false ;; esac; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
        printf 'FAIL %s\n  missing:  %s\n  in:       %s\n' "$1" "$2" "$3" >&2
    fi
}

# Assert the haystack does NOT contain the needle substring.
# Args: label needle haystack
assert_absent() {
    if case "$3" in *"$2"*) false ;; *) true ;; esac; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
        printf 'FAIL %s\n  unexpected: %s\n  in:         %s\n' "$1" "$2" "$3" >&2
    fi
}

# ------------------------------------------------------------------------------
# _neodiff_vstr: single-quoted Vimscript literal, embedded quotes doubled
# ------------------------------------------------------------------------------
assert_eq "vstr plain" "'plain'" "$(_neodiff_vstr 'plain')"
assert_eq "vstr quote" "'it''s'" "$(_neodiff_vstr "it's")"

# ------------------------------------------------------------------------------
# _neodiff_entry: dict literal, optional status/pinned fields
# ------------------------------------------------------------------------------
assert_eq "entry basic" \
    "{'label': 'lbl', 'file': 'f', 'setup': 's', 'stat': '+1 -2'}" \
    "$(_neodiff_entry lbl f s '+1 -2' '' '')"
assert_contains "entry status" ", 'status': 'M'" \
    "$(_neodiff_entry lbl f s '' M '')"
assert_contains "entry pinned" ", 'pinned': 1" \
    "$(_neodiff_entry lbl f s '' '' pinned)"
assert_absent "entry no status" "'status'" \
    "$(_neodiff_entry lbl f s '' '' '')"

# ------------------------------------------------------------------------------
# _neodiff_diff_setup: per-status Ex command bodies + right_wt branch
# ------------------------------------------------------------------------------
# Added: empty scratch on the left, blob on the right.
added=$(_neodiff_diff_setup A HEAD~1 HEAD 0 '' dir/new.c)
assert_contains "setup A gedit" "Gedit HEAD:dir/new.c" "$added"
assert_contains "setup A vnew" "leftabove vnew" "$added"
# Deleted: old blob on the left, empty scratch on the right.
deleted=$(_neodiff_diff_setup D HEAD~1 HEAD 0 '' del.txt)
assert_contains "setup D gedit" "Gedit HEAD~1:del.txt" "$deleted"
assert_contains "setup D vnew" "rightbelow vnew" "$deleted"
# Renamed: the old blob at the old path vs the new content.
renamed=$(_neodiff_diff_setup R HEAD~1 HEAD 0 rename_src.txt rename_dst.txt)
assert_contains "setup R oldpath" "Gvdiffsplit HEAD~1:rename_src.txt" "$renamed"
# Modified with a right revision loads the newer blob explicitly.
mod_rev=$(_neodiff_diff_setup M HEAD~1 HEAD 0 '' dir/mod.c)
assert_contains "setup M rev gedit" "Gedit HEAD:dir/mod.c" "$mod_rev"
assert_contains "setup M rev split" "Gvdiffsplit HEAD~1:dir/mod.c" "$mod_rev"
# Modified against the working tree (right_wt=1) has no explicit right load.
mod_wt=$(_neodiff_diff_setup M :0 '' 1 '' keep.txt)
assert_contains "setup M wt split" "Gvdiffsplit :0:keep.txt" "$mod_wt"
assert_absent "setup M wt no gedit" "Gedit" "$mod_wt"

# ------------------------------------------------------------------------------
# _neodiff_parse_changes: against the fixture repo, per argument pattern
# ------------------------------------------------------------------------------
fixture=$(mktemp -d)/fx
bash "$script_dir/mkrepo.sh" "$fixture"
toplevel="$fixture"
cd "$fixture" || exit 1

# Commit form (gshow): A/M/D/R present, submodule 'sub' skipped (it is a dir).
_neodiff_parse_changes HEAD~1 HEAD 0 git diff-tree %FMT% --no-commit-id -r HEAD
label_count=$(printf '%s' "$_ndf_entries" | grep -o "'label':" | wc -l | tr -d ' ')
assert_eq "parse commit count" "4" "$label_count"
assert_eq "parse commit args" "4" "${#_ndf_args[@]}"
assert_contains "parse commit A" "'label': 'dir/new.c', 'file': '$fixture/dir/new.c', 'setup': 'try | Gedit HEAD:dir/new.c" "$_ndf_entries"
assert_contains "parse commit A status" "'label': 'dir/new.c'" "$_ndf_entries"
assert_contains "parse commit D" "'label': 'del.txt'" "$_ndf_entries"
assert_contains "parse commit R" "'label': 'rename_dst.txt'" "$_ndf_entries"
assert_contains "parse commit R oldpath" "Gvdiffsplit HEAD~1:rename_src.txt" "$_ndf_entries"
assert_absent "parse commit skips submodule" "'label': 'sub'" "$_ndf_entries"

# Staged form (--cached): index vs HEAD, one modified file.
_neodiff_parse_changes HEAD :0 0 git diff %FMT% --cached
assert_eq "parse staged args" "1" "${#_ndf_args[@]}"
assert_contains "parse staged file" "'label': 'keep.txt'" "$_ndf_entries"

# Working-tree form (no args): right_wt=1, no explicit right-side load.
_neodiff_parse_changes :0 '' 1 git diff %FMT%
assert_eq "parse worktree args" "1" "${#_ndf_args[@]}"
assert_contains "parse worktree split" "Gvdiffsplit :0:keep.txt" "$_ndf_entries"
assert_absent "parse worktree no gedit" "Gedit" "$_ndf_entries"

# ------------------------------------------------------------------------------
# gdiff argument classification: a pathspec must not be taken as a revision.
# Regression: `gdiff <path>` produced `Gvdiffsplit <path>:<path>`, an unresolvable
# revision, instead of the working-tree diff of that path. Stub the launcher to
# capture what gdiff would hand to Vim.
# ------------------------------------------------------------------------------
_cap_title=""
_cap_entries=""
_cap_refresh=""
_neodiff_launch() { _cap_title="$2"; _cap_entries="$3"; _cap_refresh="$4"; }

gdiff keep.txt
assert_contains "gdiff pathspec: working-tree rev" "Gvdiffsplit :0:keep.txt" "$_cap_entries"
assert_absent "gdiff pathspec: not a revision" "keep.txt:keep.txt" "$_cap_entries"

gdiff -- keep.txt
assert_contains "gdiff -- pathspec: working-tree rev" "Gvdiffsplit :0:keep.txt" "$_cap_entries"

gdiff HEAD~1 -- keep.txt
assert_contains "gdiff rev + pathspec: keeps the rev" "Gvdiffsplit HEAD~1:keep.txt" "$_cap_entries"

# ------------------------------------------------------------------------------
# gdiff range: pin a "Diff Commits" folder listing the commits in the range, one
# pinned entry per commit; a non-range diff pins nothing, and the pinned-commit
# state must not leak from a prior range call. Ranges skip the :w stat refresh.
# ------------------------------------------------------------------------------
rangerepo=$(mktemp -d)/rr
rr_git() { git -C "$rangerepo" -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$rangerepo"
rr_git init -q
printf '1\n' > "$rangerepo/f.txt"; rr_git add -A; rr_git commit -q -m base
printf '2\n' > "$rangerepo/f.txt"; rr_git add -A; rr_git commit -q -m second
printf '3\n' > "$rangerepo/f.txt"; rr_git add -A; rr_git commit -q -m third
cd "$rangerepo" || exit 1

gdiff HEAD~2..HEAD
assert_contains "gdiff range: pins Diff Commits folder" "'label': 'Diff Commits/" "$_cap_entries"
assert_contains "gdiff range: pinned entries are pinned" "'pinned': 1" "$_cap_entries"
assert_eq "gdiff range: one pinned entry per commit" "2" \
    "$(printf '%s' "$_cap_entries" | grep -o 'Diff Commits/' | wc -l | tr -d ' ')"
assert_eq "gdiff range: no :w refresh" "[]" "$_cap_refresh"

# A single bare revision is not a range: no pinned commits, and no stale ones
# from the range call above.
gdiff HEAD~1
assert_absent "gdiff non-range: no Diff Commits" "Diff Commits/" "$_cap_entries"

# gshow of a single commit shows that commit; gshow of a range is handed to gdiff
# (which pins the Diff Commits list), rather than erroring on the range endpoint.
gshow HEAD
assert_contains "gshow commit: title" "Git Show HEAD" "$_cap_title"
assert_contains "gshow commit: pins the commit description" "'label': 'Commit Description'" "$_cap_entries"
assert_absent "gshow commit: no Diff Commits" "Diff Commits/" "$_cap_entries"

gshow HEAD~2..HEAD
assert_contains "gshow range: delegates to gdiff (title)" "Git Diff HEAD~2..HEAD" "$_cap_title"
assert_contains "gshow range: delegates to gdiff (Diff Commits)" "'label': 'Diff Commits/" "$_cap_entries"

gshow 'HEAD~2..'
assert_contains "gshow open range: delegates to gdiff" "'label': 'Diff Commits/" "$_cap_entries"

cd "$fixture" || exit 1

# ------------------------------------------------------------------------------
# install.sh: writes an idempotent, marker-guarded source block into an rc file.
# ------------------------------------------------------------------------------
tmprc=$(mktemp)
printf 'existing line\n' > "$tmprc"
bash "$repo_root/shell/install.sh" "$tmprc" >/dev/null
assert_eq "install writes one block" "1" "$(grep -cF '>>> neodiff >>>' "$tmprc")"
assert_contains "install sources neodiff.sh" "shell/neodiff.sh" "$(cat "$tmprc")"
assert_contains "install preserves existing content" "existing line" "$(cat "$tmprc")"
bash "$repo_root/shell/install.sh" "$tmprc" >/dev/null
assert_eq "install is idempotent" "1" "$(grep -cF '>>> neodiff >>>' "$tmprc")"
rm -f "$tmprc"

# ------------------------------------------------------------------------------
# Syntax check under zsh (the module is sourced by zsh in real use).
# ------------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$repo_root/shell/neodiff.sh"; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
        echo "FAIL zsh -n shell/neodiff.sh" >&2
    fi
fi

# ------------------------------------------------------------------------------
echo "shell tests: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ]
