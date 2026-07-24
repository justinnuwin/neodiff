# neodiff - Vim-powered `git show` / `git diff` viewer

A pair of shell aliases (`gshow`, `gdiff`) that opens a commit or diff in Vim
with one tab per changed file, plus a "global" sidebar for navigation.

This project is distinct from the diffview.nvim plugin which performs similar
functionality but is completely powered from within vim. This project actively
incorporates git from the shell to perform the heavy lifting.

---

## Installation

Install the Vim plugin with any plugin manager, e.g. with vim-plug:

```
Plug 'justinnuwin/neodiff'
```

The `gshow` / `gdiff` aliases come from the shell launchers, which must be
sourced from your shell rc. Let the plugin manager do it on install with a
post-update hook (`shell/install.sh` appends an idempotent, marker-guarded
`source` block to `~/.bashrc` / `~/.zshrc`):

```
Plug 'justinnuwin/neodiff', { 'do': './shell/install.sh' }
```

Or wire it up by hand:

```
source /path/to/neodiff/shell/neodiff.sh
```

`shell/install.sh` also accepts explicit rc paths (or `$NEODIFF_RC`) and is safe
to re-run -- it refreshes its block in place rather than duplicating it.

`tpope/vim-fugitive` is required (the diffs use `:Gedit` / `:Gvdiffsplit`).

---

## Quick reference

| Action | Key / command |
| --- | --- |
| Open commit | `gshow [rev]` |
| Open working diff | `gdiff` |
| Open staged diff | `gdiff --staged` |
| Diff revisions | `gdiff <rev>` or `gdiff <rev1> <rev2>` |
| Next / prev file tab | `gt` / `gT` |
| Select file / toggle dir (sidebar) | `<CR>`, `o`, or mouse click |
| Toggle the sidebar | `<C-b>` |
| Search symbols in changed files | `<C-p>` (needs ctags; uses fzf if available) |
| Close a file's tab | `:q` in a diff pane |
| Next / prev change in file | `]c` / `[c` (built-in diff) |
| Open / close all folds (diff pane) or tree (sidebar) | `zR` / `zM` |

Config: `g:neodiff_width` (sidebar width, default 52);
`g:neodiff_status_symbols` (status glyphs); `NEODIFF_FIND_COPIES=1` (enable
copy detection).
