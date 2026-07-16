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

Then source the shell launchers from your shell rc so `gshow` / `gdiff` are
defined:

```
source /path/to/neodiff/shell/neodiff.sh
```

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
| Close a file's tab | `:q` in a diff pane |
| Next / prev change in file | `]c` / `[c` (built-in diff) |

Config: `g:neodiff_width` (sidebar width, default 52);
`g:neodiff_status_symbols` (status glyphs); `NEODIFF_FIND_COPIES=1` (enable
copy detection).
