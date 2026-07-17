# Development Notes & Requirements

This document captures the design, the code structure, the conventions used, the
non-obvious implementation lessons, and the planned next steps.

---

## Goals

Accumulated over the course of building this tool:

1. `gshow [rev]` shows a commit (default `HEAD`): tab 1 = commit description,
   optional notes tab, then one vertical-diff tab per changed file.
2. `gdiff [args]` shows a diff: working-tree (no args), a single revision
   (rev vs working tree), two revisions (rev vs rev), or `--staged`/`--cached`
   (index vs HEAD - the *actual staged change*, not the whole file). Arbitrary
   `git diff` flags pass through for file selection.
3. A sidebar shows only the files involved, as a directory tree (like NERDTree
   scoped to the diff), shown identically in every tab.
4. Selecting a file switches to the tab already showing its diff (never clobbers
   the layout by loading it into the current window); selecting a directory
   toggles it; if a file's tab was closed, selecting it reopens the diff.
5. Closing a diff window (`:q`) closes the whole tab.
6. The two diff panes stay equalized on tab switch and window resize.
7. Matching diff folds on both panes (only the changed regions shown).
8. Per-file added/removed line counts in the sidebar, aligned into one column.
9. A gray **title bar** (not a tab bar): `Git Diff/Show <what> (N tabs open)`
   centered, with the previous file (`gT` target) at the far left and the next
   file (`gt` target) at the far right.
10. The sidebar pane header shows `neodiff` with a right-aligned `(? for help)`
    hint.
11. For working-tree diffs, the sidebar stats refresh on every `:w` (edits made
    in the diff update the stats live).
12. No prompts for swap files / already-open files (open read-only instead).
13. No spurious red clangd/clang-tidy diagnostics in the diff (coc navigation is
    kept; only diagnostics are disabled per buffer).
14. The tree auto-expands when it fits in ~150% of the screen height, else all
    directories start collapsed.
15. The sidebar is mouse-clickable (click a file to jump, a folder to toggle).

---

## Non-obvious implementation notes (lessons learned)

These are the traps that cost real debugging time; keep them in mind before
"simplifying":

- **`tabpagemax` defaults to 10.** `vim -p` silently drops tabs past 10, so a
  34-file commit showed only 10 diffs. We raise it to the file count via
  `--cmd "set tabpagemax=N"`.
- **NERDTree netrw hijack -> E121.** `g:NERDTreeHijackNetrw` (on by default)
  turns any *directory* buffer into a NERDTree window tree; in this multi-tab
  layout its `BufLeave` autocmd crashes with `E121: Undefined variable:
  b:NERDTree`. A modified **submodule** is a directory, so it triggered this. We
  (a) skip directories/submodules from the file list and (b) set
  `g:NERDTreeHijackNetrw = 0` for the session.
- **Red C++ `&` = coc/clangd diagnostics**, not syntax and not the diff colors.
  clangd can't compile the diff buffers, so it paints spurious diagnostics. We
  set `b:coc_diagnostic_disable = 1` per buffer (keeps navigation/hover).
- **`--staged` is a flag, not a revision.** Treating it as a rev
  (`Gvdiffsplit --staged`) showed the whole file. Staged now maps to
  `Gedit :0:% | Gvdiffsplit HEAD` (index vs HEAD).
- **Fold asymmetry** was a foldlevel difference; both diff windows are forced to
  `foldmethod=diff foldlevel=0`.
- **Stable tab ids** (`t:neodiff_id`, = entry index) are what make "jump to
  tab", "reopen closed tab", and "close-tab-on-quit" robust against tab
  reordering. Do not key off tab numbers or buffer names (diff buffers become
  `fugitive://...` blobs).
- **Can't close a tab from inside `QuitPre`** while the `:q` is unwinding; we
  defer via `timer_start(0, ...)`.
- **Testing artifacts:** headless `vim -u ~/.vimrc -es` runs in **'compatible'
  mode**, which makes coc/fugitive/quick-scope throw noise (`E10`, `E15`, ...)
  that does *not* occur in a real terminal. Always test with `-N` (nocompatible)
  and ignore coc's `-es`-only errors.

---

## Code structure

The repo ships both halves of the tool: a Vim plugin and the shell launchers.

### `shell/neodiff.sh`

The user-facing entry points and the glue that launches Vim.

- `_neodiff_tmux_zoom` - zoom the tmux pane if inside tmux.
- `_neodiff_vstr <s>` - emit a single-quoted Vimscript string literal
  (doubles embedded `'`; uses `sed` so it behaves identically in bash and zsh).
- `_neodiff_entry <label> <file> <setup> <stat>` - emit one Vimscript dict
  literal `{'label':.., 'file':.., 'setup':.., 'stat':..}`.
- `gshow [rev]` - collects the commit description, notes, and changed files;
  builds the `entries` list; launches Vim.
- `gdiff [args]` - parses args (staged/cached, revision count), picks the diff
  setup, collects files + numstat, builds `entries` and the `refresh` command;
  launches Vim.

Both build an `args` array (what `vim -p` opens: one buffer per tab) parallel to
an `entries` Vimscript list, then run:

```
vim --cmd "set tabpagemax=<N>" \
    --cmd "let g:NERDTreeHijackNetrw = 0" \
    --cmd "autocmd BufEnter * let b:coc_diagnostic_disable = 1" \
    --cmd "autocmd SwapExists * let v:swapchoice = 'o'" -p <files...> \
    +"cd <toplevel>" \
    +"call neodiff#Setup(<title>, <entries>, <refresh>)"
```

### `plugin/neodiff.vim` and `autoload/neodiff.vim`

The sidebar plugin. `plugin/neodiff.vim` loads eagerly: it holds the
`g:loaded_neodiff` guard and the user-overridable config defaults
(`g:neodiff_width`, `g:neodiff_status_symbols`). `autoload/neodiff.vim` holds the
implementation, loaded lazily the first time `neodiff#Setup` is called; it owns
all tab setup, the sidebar rendering, and the title bar.

**Data model (script-scoped state):**

- `s:entries` - list of `{'label','file','setup','stat', ['status','pinned']}`;
  the list **index is the stable tab id** (survives tab reordering/closing).
  `label` is the repo-relative (new) path; `file` is the buffer to open; `setup`
  is the Ex command that turns that buffer into the diff; `stat` is the display
  string (`+N -M`, `bin`, or empty); `status` is the git status letter
  (`A`/`M`/`D`/`R`/`C`) shown in the far-left column; `pinned` lifts a meta entry
  (commit description / notes) above the tree.
- `s:tree` - nested `{'dirs': {name: node}, 'files': {name: id}, 'name','path'}`
  built from the unpinned entry labels; file leaves store the entry id.
- `s:pinned_tree` - same node shape as `s:tree`, built from pinned entries whose
  label contains a `/` (the pinned folder(s) shown above the diff tree).
- `s:collapsed` - set of collapsed directory paths.
- `s:line_to_node` - maps a sidebar line number to `{'type':'dir','path'}` or
  `{'type':'file','id'}` (rebuilt on every render; non-selectable lines like the
  header are simply absent).
- `s:nav_order` - entry ids in sidebar (tree-display) order; `gt`/`gT` and the
  title bar walk this so navigation follows the visible tree, not tab order.
- `s:refresh` - argv list for the numstat refresh command (empty = no refresh).
- `s:pending_close` - tab ids queued for deferred close.

**Public API (called from the shell):**

- `neodiff#Setup(title, entries, refresh)` - builds the tree, sets the title
  bar, applies each entry's `setup` to its already-open tab, tags each tab with
  `t:neodiff_id`, opens the sidebar in every tab, and registers the autocmds.
- `neodiff#Title()` - `tabline` function; renders the title bar.

**Internals (roughly in flow order):**

- `s:BuildTree`, `s:NewNode`, `s:CountNodes`, `s:CollapseAll` - tree construction
  and the auto-expand-vs-collapse decision.
- `s:PrepareTab(id)` - run one entry's setup, tag the tab, match diff folds, open
  the sidebar. Reused for reopening a closed tab.
- `s:SetupTitleBar`, `neodiff#Title` - the gray centered title bar with
  prev/next file names.
- `s:OpenSidebar`, `s:SidebarWinnr`, `s:EnsureSidebar`, `s:SetupSyntax` - the
  sidebar window (a single reused scratch buffer shown in every tab).
- `s:BuildLines`, `s:Rebuild`, `s:Render` - build the tree lines, align the stat
  column, write the buffer, and park the cursor on the current tab's entry.
- `s:Select`, `s:GotoOrReopen` - handle `<CR>`/`o`/click: toggle a directory, or
  jump to / reopen a file's tab (by stable id).
- `s:RefreshStats` - re-run numstat on `:w`, update every entry's `stat`,
  re-render.
- `s:OnQuitPre`, `s:DrainClose` - close the whole tab when a diff window is
  quit (deferred via `timer_start(0, ...)`).

---

## Data flow

```
gshow/gdiff (shell)
  |  git plumbing: diff-tree/diff --name-status, --numstat, notes, show
  |  build args[] (files, in tab order) and entries[] (parallel dicts)
  v
vim -p args...  +cd  +call neodiff#Setup(title, entries, refresh)
  |  vim opens one tab per file (tabpagemax raised to cover all files)
  v
neodiff#Setup (plugin)
  |  BuildTree(labels) ; per tab: PrepareTab(id) -> run setup, tag, open sidebar
  |  register autocmds (TabEnter/QuitPre/VimResized[/BufWritePost])
  v
interaction: Select -> GotoOrReopen ; :q -> OnQuitPre/DrainClose ; :w -> RefreshStats
```

The shell never writes a temporary Vimscript file; everything is passed as
`--cmd`/`+cmd` arguments and a single `neodiff#Setup(...)` call.

---

## Coding preferences / conventions

- **ASCII only** in code, comments, and strings (arrows written `->`, `<-`).
- **Descriptive variable names** - no single-letter locals or loop variables in
  either file (e.g. `changed_file`, `rev_count`, `stat_path`, `l:entry_id`,
  `l:sidebar_winnr`, `l:prev_win`).
- **Legacy Vimscript** (`function!`, `let l:...`) to match the repo's existing
  `.vim` helpers (`bazel_utils.vim`, `cpp_utils.vim`); the plugin is `source`d,
  not a `vim9script`.
- **Portable shell** - the module has a `#!/bin/bash` shebang but is sourced by
  zsh, so anything shell-specific is validated against zsh (`zsh -n`) and quoting
  uses `sed`/`printf` rather than `${//}` (which differs between bash and zsh).
- **Minimal, surgical changes**; comments explain *why*, especially the
  non-obvious workarounds below.

---

## File statuses

Every changed file carries a git status, sourced from `git diff[-tree]
--name-status -M -z` (paired with `--numstat -M -z` for line counts; both are
NUL-parsed, so spaces and renames are handled). A colored symbol sits in a
far-left column:

| Status | Meaning | Default color |
| --- | --- | --- |
| `A` | added | green |
| `M` | modified | yellow |
| `D` | deleted | red |
| `R` | renamed / moved | magenta |
| `C` | copied | cyan |

`diff_setup` is built per status (by `_neodiff_diff_setup`) so each diff is
meaningful: added shows empty-vs-new, deleted old-vs-empty, renamed/copied the
old blob at the old path vs the new content, modified the same path on both
sides. The older side is always on the left.

- Symbols are configurable via `g:neodiff_status_symbols` (defaults are Nerd
  Font octicon diff glyphs); set it to `{'A':'A','M':'M','D':'D','R':'R','C':'C'}`
  for plain letters.
- Copy detection (`C`) is off by default; set `NEODIFF_FIND_COPIES=1` to enable
  `-C --find-copies-harder` (O(files^2) on large trees).

---

## Testing

`./ci/run.sh` builds a pinned CI container (`ci/Dockerfile`: shellcheck, vint,
vim 8.2, neovim 0.12.4, git, vim-fugitive, universal-ctags) and runs,
aggregating exit codes:

- **shellcheck** over the shell scripts, and **vint** over `plugin/`/`autoload/`
  (config in `.vintrc.yaml`).
- **Functional tests** (`ci/run_functional.vim`, helpers in `ci/fixtures.vim`):
  a hand-rolled headless runner that drives the public `neodiff#Setup()` with
  fixture entries (empty `setup`, so no fugitive) and asserts on the sidebar
  buffer, tab state, and `neodiff#Title()`. It runs on both vim and neovim and
  covers tree/sort order, the collapse threshold, directory toggle,
  select-to-tab, reopen-after-close, close-tab-on-`:q`, stat-column alignment,
  the title bar, and `RefreshStats`/rename-path handling against a temp repo.
- **Shell tests** (`ci/test_neodiff.sh`): assertions on the Vimscript string
  builders, `_neodiff_parse_changes` for each argument pattern (also exercises
  the submodule/dir skip, driven by `ci/mkrepo.sh`), the gdiff pathspec-vs-rev
  classification, and the install-hook block.
- **Fugitive/ctags integration** (`ci/integration.vim`, `ci/test_symbols.vim`):
  container-only checks that need a real diff or ctags -- that the blame maps are
  stripped from the diff panes, and that `neodiff#CollectSymbols()` finds the
  right symbols and attributes them to the right entries.
- **Golden screen-dumps** (`ci/screendump.vim` + `ci/screendump_inner.vim`): an
  outer Vim runs each editor inside `term_start` on a fixed-path fixture and
  `term_dumpwrite()`s the screen, compared to `ci/dumps/*.golden`. This is the
  only check that verifies the *rendered* view -- status glyph colors, the diff
  pane tinting, the deletion hatch, the gray title bar, and fold rendering.
  Regenerate the goldens with `NEODIFF_UPDATE=1 ./ci/run.sh` (they are valid only
  against the pinned editor versions in `ci/Dockerfile`).

**Not auto-tested** (behavioral, need a real terminal/session): tmux pane zoom
(`_neodiff_tmux_zoom`), an actual mouse click (the `<LeftRelease>` *handler* is
exercised via its mapping, but not a real click event), coc/clangd diagnostic
suppression (needs coc loaded), and the symbol-search picker UI (the fzf /
inputlist prompt -- `neodiff#CollectSymbols()` and the jump are tested, but the
interactive selection is not). Verify these by hand when touched.
