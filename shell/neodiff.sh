#!/bin/bash
# ==============================================================================
# neodiff - Vim-powered git show / git diff aliases.
#
# A companion to the neodiff Vim plugin: gshow / gdiff open one Vim tab per
# changed file and hand the file list to the plugin's sidebar via
# neodiff#Setup(...).
# ==============================================================================

# Zoom the current tmux pane, if running inside tmux and not already zoomed.
_neodiff_tmux_zoom() {
    if [ -n "$TMUX" ] && [ "$(tmux display-message -p '#{window_zoomed_flag}')" -eq 0 ]; then
        tmux resize-pane -Z
    fi
}

# Emit a single-quoted Vimscript string literal, doubling any embedded single
# quote so the result parses as a valid literal.
# Args:
#   string - the text to quote
_neodiff_vstr() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Emit one Vimscript dict literal describing a tab:
#   {'label':.., 'file':.., 'setup':.., 'stat':.. [, 'status':.., 'pinned': 1]}
# Args:
#   label  - the entry's sidebar label (a file's repo-relative path)
#   file   - buffer to open in the tab
#   setup  - Ex command that turns that buffer into the diff
#   stat   - stat display string ("+N -M", "bin", or empty)
#   status - git status letter (A/M/D/R/C); emitted only when non-empty
#   pinned - if non-empty, pins the entry above the diff tree
_neodiff_entry() {
    printf "{'label': %s, 'file': %s, 'setup': %s, 'stat': %s" \
        "$(_neodiff_vstr "$1")" "$(_neodiff_vstr "$2")" \
        "$(_neodiff_vstr "$3")" "$(_neodiff_vstr "$4")"
    [ -n "$5" ] && printf ", 'status': %s" "$(_neodiff_vstr "$5")"
    [ -n "$6" ] && printf ", 'pinned': 1"
    printf "}"
}

# Build the Ex command that turns a file's tab into its diff, chosen by git
# status: an added file shows as all-green, a deleted file as all-red, and a
# modified/renamed/copied file as a side-by-side diff with the older content on
# the left.
# Args:
#   status   - git status letter (A/M/D/R/C)
#   lrev     - older/left revision
#   rrev     - newer/right revision (unused when right_wt=1)
#   right_wt - 1 if the tab's working-tree buffer is already the newer (right)
#              pane, else 0 to load the newer side from rrev
#   old_path - pre-rename path, for R/C
#   new_path - the file's current path
_neodiff_diff_setup() {
    local st="$1" lrev="$2" rrev="$3" right_wt="$4" oldp="$5" newp="$6"
    # A forced-empty scratch pane opposite a real blob renders an added file as
    # all-green and a deleted file as all-red.
    local scratch="setlocal buftype=nofile bufhidden=wipe noswapfile nomodifiable"
    local right body
    if [ "$right_wt" = 1 ]; then right=""; else right="Gedit $rrev:$newp | "; fi
    # fugitive's Gvdiffsplit opens its argument (the older blob) on the left,
    # which the plugin's pane coloring relies on for red-left / green-right.
    case "$st" in
        A)  body="${right}diffthis | leftabove vnew | $scratch | diffthis" ;;
        D)  body="Gedit $lrev:$newp | diffthis | rightbelow vnew | $scratch | diffthis" ;;
        R|C) body="${right}Gvdiffsplit $lrev:$oldp" ;;
        *)  body="${right}Gvdiffsplit $lrev:$newp" ;;
    esac
    printf 'try | %s | catch | endtry' "$body"
}

# From a git diff invocation, populate two parallel arrays over the changed
# files: _ndf_args (the buffer path to open for each file) and _ndf_entries (the
# comma-joined Vimscript entry dicts). Rename/copy-aware; a directory or
# submodule that a diff may list is skipped. Copy detection is opt-in via
# NEODIFF_FIND_COPIES.
# Args:
#   lrev rrev right_wt - passed through to _neodiff_diff_setup for each file.
#   <prefix...>        - the git command to run, with a literal %FMT% token where
#                        the output-format flag belongs so it precedes any user
#                        `-- <paths>`, e.g. `git diff %FMT% "$@"` or
#                        `git diff-tree %FMT% --no-commit-id -r "$rev"`.
# Reads $toplevel from the calling function's scope.
_neodiff_parse_changes() {
    local lrev="$1" rrev="$2" right_wt="$3"; shift 3
    local -a detect=(-M)
    # Copy detection is O(files^2), so it stays opt-in via NEODIFF_FIND_COPIES.
    [ -n "$NEODIFF_FIND_COPIES" ] && detect+=(-C --find-copies-harder)

    # Expand %FMT% into each pass's format flags, keeping every other token
    # in place.
    local -a num_cmd=() ns_cmd=() tok
    for tok in "$@"; do
        if [ "$tok" = "%FMT%" ]; then
            num_cmd+=(--numstat "${detect[@]}" -z)
            ns_cmd+=(--name-status "${detect[@]}" -z)
        else
            num_cmd+=("$tok"); ns_cmd+=("$tok")
        fi
    done

    # Pass 1: counts keyed by the post-rename new path. With -z each numstat
    # record is NUL-terminated; a rename's path field is empty and is followed by
    # two extra NUL tokens, so the new-path key needs no `{old => new}` parsing.
    typeset -A _ndf_counts
    local rec add del pathfield np
    while IFS= read -r -d '' rec; do
        add="${rec%%$'\t'*}"; rec="${rec#*$'\t'}"
        del="${rec%%$'\t'*}"; pathfield="${rec#*$'\t'}"
        if [ -z "$pathfield" ]; then
            IFS= read -r -d '' _        # old (discard)
            IFS= read -r -d '' np       # new
        else
            np="$pathfield"
        fi
        if [ "$add" = "-" ]; then _ndf_counts[$np]="bin"; else _ndf_counts[$np]="+$add -$del"; fi
    done < <("${num_cmd[@]}")

    # Pass 2: status + paths in git's order. A/M/D: "status\0path"; R/C:
    # "score\0old\0new" (score stripped to the bare letter).
    _ndf_args=(); _ndf_entries=""
    local st oldp newp setup stat
    while IFS= read -r -d '' tok; do
        case "$tok" in
            R*|C*) IFS= read -r -d '' oldp; IFS= read -r -d '' newp; st="${tok%%[0-9]*}" ;;
            *)     IFS= read -r -d '' newp; oldp=""; st="$tok" ;;
        esac
        [ -z "$newp" ] && continue
        [ -d "$toplevel/$newp" ] && continue
        stat="${_ndf_counts[$newp]}"
        setup=$(_neodiff_diff_setup "$st" "$lrev" "$rrev" "$right_wt" "$oldp" "$newp")
        _ndf_args+=("$toplevel/$newp")
        _ndf_entries+="${_ndf_entries:+, }$(_neodiff_entry "$newp" "$toplevel/$newp" "$setup" "$stat" "$st")"
    done < <("${ns_cmd[@]}")
}

# Launch Vim on the changed-file buffers and hand them to the neodiff plugin.
# Args:
#   toplevel - repo root; Vim is launched from and cd'd into it
#   title    - quoted Vimscript title string, passed to neodiff#Setup
#   entries  - Vimscript entries-list literal, passed to neodiff#Setup
#   refresh  - Vimscript refresh-list literal ([] to disable), passed to
#              neodiff#Setup
#   file...  - buffer paths to open, one tab each (via vim -p)
_neodiff_launch() {
    local toplevel="$1" title="$2" entries="$3" refresh="$4"; shift 4

    _neodiff_tmux_zoom

    # Launch from the repo root in a subshell so a removed cwd (e.g. `git rm`
    # deleting the last file in the directory you are standing in) cannot start
    # Vim in a dead cwd, which aborts config loading before neodiff#Setup exists.
    #
    # --cmd runs before any file loads:
    #   - tabpagemax must cover every file or Vim's default of 10 silently drops
    #     the rest.
    #   - SwapExists opens files read-only instead of prompting on a swap or
    #     already-open conflict.
    #   - NERDTreeHijackNetrw=0 stops NERDTree from taking over a directory
    #     buffer, which otherwise crashes its BufLeave autocmd with E121 in this
    #     multi-tab layout.
    #   - b:coc_diagnostic_disable turns off coc/clangd diagnostics per buffer
    #     (clangd cannot compile the diff buffers, so it paints spurious red
    #     diagnostics) while keeping coc navigation/hover.
    #
    # neodiff#Setup then applies each entry's diff setup, tags the tabs, builds
    # the sidebar, and (with a non-empty refresh) updates stats on save.
    ( cd "$toplevel" && vim --cmd "set tabpagemax=$#" \
        --cmd "let g:NERDTreeHijackNetrw = 0" \
        --cmd "autocmd BufEnter * let b:coc_diagnostic_disable = 1" \
        --cmd "autocmd SwapExists * let v:swapchoice = 'o'" -p "$@" \
        +"cd $toplevel" \
        +"call neodiff#Setup($title, $entries, $refresh)" )
}

# ------------------------------------------------------------------------------
# gshow - open a commit's diff in Vim, one tab per changed file.
#
# Args:
#   [rev] - the commit to show; defaults to HEAD.
#
# Tab 1 shows the commit description, pinned above the tree in the sidebar, and
# any git notes on the commit follow in a collapsible "Commit Notes" folder, one
# entry per namespace. The sidebar lists every tab; selecting an entry jumps to
# it. The tmux pane is zoomed while viewing when inside a tmux session.
# ------------------------------------------------------------------------------
gshow() {
    local rev="${1:-HEAD}"
    if ! git rev-parse --verify "$rev" >/dev/null 2>&1; then
        echo "Error: Revision '$rev' not found." >&2
        return 1
    fi

    local toplevel tmpdir
    toplevel=$(git rev-parse --show-toplevel)
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    # Commit description (title + body) shown in the first tab.
    git show --no-patch --pretty=fuller "$rev" > "$tmpdir/COMMIT_DESCRIPTION"

    # Collect any git notes attached to the commit, one file per namespace. Each
    # becomes a pinned "Commit Notes/<namespace>" entry, so the sidebar groups
    # them in a collapsible "Commit Notes" folder pinned above the diff tree.
    mkdir -p "$tmpdir/notes"
    local ref content note_ns
    local note_namespaces=()
    for ref in $(git for-each-ref --format='%(refname)' refs/notes); do
        content=$(git notes --ref="$ref" show "$rev" 2>/dev/null)
        if [ -n "$content" ]; then
            note_ns="${ref##*/}"
            echo "$content" > "$tmpdir/notes/$note_ns"
            note_namespaces+=("$note_ns")
        fi
    done

    # Status-aware entries for every changed file in this commit, comparing it
    # against its parent. Fills _ndf_args and _ndf_entries.
    _neodiff_parse_changes "$rev~1" "$rev" 0 git diff-tree %FMT% --no-commit-id -r "$rev"

    # Tab order: commit description, optional notes, then one tab per file. args
    # is what `vim -p` opens; entries is the parallel list of dict literals the
    # plugin uses to build the diffs, tag tabs, show stats, and reopen a tab if it
    # is closed.
    local args=("$tmpdir/COMMIT_DESCRIPTION")
    local entries
    entries="[$(_neodiff_entry "Commit Description" "$tmpdir/COMMIT_DESCRIPTION" "setlocal readonly nomodifiable" "" "" "pinned")"
    for note_ns in "${note_namespaces[@]}"; do
        args+=("$tmpdir/notes/$note_ns")
        entries+=", $(_neodiff_entry "Commit Notes/$note_ns" "$tmpdir/notes/$note_ns" "setlocal readonly nomodifiable" "" "" "pinned")"
    done
    args+=("${_ndf_args[@]}")
    [ -n "$_ndf_entries" ] && entries+=", $_ndf_entries"
    entries+="]"

    local title
    title=$(_neodiff_vstr "Git Show $rev")
    # A commit's diff is against committed state, so its stats never change:
    # pass an empty refresh command.
    _neodiff_launch "$toplevel" "$title" "$entries" "[]" "${args[@]}"
}

# ------------------------------------------------------------------------------
# gdiff - open a diff in Vim, one tab per changed file.
#
# Args -- any git-diff arguments; the diff wiring keys off these forms:
#   (none)               - the current unstaged changes.
#   --staged / --cached  - the staged changes (index vs HEAD).
#   <rev>                - that revision vs the working tree.
#   <rev1>..<rev2>       - range endpoints (A...B uses their merge-base).
#   <rev1> <rev2>        - two revisions.
# Other flags pass through to git for file selection. The sidebar lists every
# tab; selecting an entry jumps to it. The tmux pane is zoomed while viewing when
# inside a tmux session.
# ------------------------------------------------------------------------------
gdiff() {
    local toplevel
    toplevel=$(git rev-parse --show-toplevel)

    # Parse args: --staged/--cached compares the index to HEAD; otherwise a
    # non-flag arg is a revision only if it is a range or resolves as one --
    # anything else (and anything after a `--`) is a pathspec that limits which
    # files show but leaves the diff wiring alone. Without this test a pathspec
    # like `gdiff src/foo.c` would be taken as the left revision, producing a
    # broken `Gvdiffsplit src/foo.c:src/foo.c`. Other flags (e.g. -w) still pass
    # through to git for file selection but do not change the wiring.
    local staged=0 rev_count=0 rev1="" rev2="" arg paths_only=0
    for arg in "$@"; do
        case "$arg" in
            --staged|--cached) staged=1 ;;
            --) paths_only=1 ;;
            -*) ;;
            *) if [ "$paths_only" -eq 0 ] \
                   && { [ "$arg" != "${arg#*..}" ] \
                        || git rev-parse --verify --quiet "$arg" >/dev/null 2>&1; }; then
                   rev_count=$((rev_count + 1))
                   if [ "$rev_count" -eq 1 ]; then rev1="$arg"; elif [ "$rev_count" -eq 2 ]; then rev2="$arg"; fi
               fi ;;
        esac
    done

    # Reduce the mode to an older/left rev (lrev) and a newer/right side: either a
    # rev (rrev) or the actual working-tree file (right_wt=1, so live edits and :w
    # refresh work). _neodiff_diff_setup builds each file's status-aware setup
    # from these. A single rev arg may be a bare revision (rev vs working tree) or
    # a range; a range must diff its two endpoints (treating "A..B" as one object
    # would show every file as wholly new). An empty range endpoint defaults to
    # HEAD, matching git's own range semantics.
    local lrev rrev="" right_wt=0
    if [ "$staged" -eq 1 ]; then
        lrev="HEAD"; rrev=":0"
    elif [ "$rev_count" -eq 0 ]; then
        lrev=":0"; right_wt=1
    elif [ "$rev_count" -eq 1 ]; then
        case "$rev1" in
            *...*)
                local range_base="${rev1%%...*}" range_target="${rev1##*...}"
                [ -z "$range_base" ] && range_base="HEAD"
                [ -z "$range_target" ] && range_target="HEAD"
                lrev=$(git merge-base "$range_base" "$range_target"); rrev="$range_target"
                ;;
            *..*)
                local range_base="${rev1%%..*}" range_target="${rev1##*..}"
                [ -z "$range_base" ] && range_base="HEAD"
                [ -z "$range_target" ] && range_target="HEAD"
                lrev="$range_base"; rrev="$range_target"
                ;;
            *)
                lrev="$rev1"; right_wt=1
                ;;
        esac
    else
        lrev="$rev1"; rrev="$rev2"
    fi

    _neodiff_parse_changes "$lrev" "$rrev" "$right_wt" git diff %FMT% "$@"
    if [ ${#_ndf_args[@]} -eq 0 ]; then
        echo "No differences found."
        return 0
    fi

    # args is what `vim -p` opens; entries is the parallel list of dict literals
    # the plugin uses to build the diffs, tag tabs, show stats, and reopen tabs.
    local args=("${_ndf_args[@]}") entries="[$_ndf_entries]"

    # When the diff involves the working tree (plain or single-revision), re-run
    # numstat on every :w so the sidebar stats track edits. Committed comparisons
    # (staged, or two revisions) never change, so skip the refresh.
    # -M so a renamed file keeps its stat on refresh; s:RefreshStats normalizes
    # the numstat `{old => new}` path form (Vim system() cannot carry -z NULs).
    local refresh
    if [ "$staged" -eq 0 ] && [ "$rev_count" -le 1 ]; then
        refresh="['git', '-C', $(_neodiff_vstr "$toplevel"), 'diff', '-M', '--numstat'"
        for arg in "$@"; do refresh+=", $(_neodiff_vstr "$arg")"; done
        refresh+="]"
    else
        refresh="[]"
    fi

    local title desc
    if [ $# -eq 0 ]; then
        desc="Git Diff (working tree)"
    else
        desc="Git Diff $*"
    fi
    title=$(_neodiff_vstr "$desc")
    _neodiff_launch "$toplevel" "$title" "$entries" "$refresh" "${args[@]}"
}
