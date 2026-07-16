" ==============================================================================
" neodiff - Vim-powered git show / git diff viewer.
"
" A companion to the gshow / gdiff shell aliases: this opens one Vim tab per
" changed file renders a single 'global' sidebar, shown identically in every
" tab for navigation.
"
" This file registers the load guard and the user-overridable config defaults,
" which exist eagerly. The public entry point neodiff#Setup(...) lives in
" autoload/neodiff.vim, loaded lazily on first use.
" ==============================================================================

if exists('g:loaded_neodiff')
    finish
endif
let g:loaded_neodiff = 1

let g:neodiff_width = get(g:, 'neodiff_width', 52)

" Symbols for the far-left git-status column, one per status (A added, M
" modified, D deleted, R renamed, C copied). Defaults are Nerd Font octicon diff
" glyphs plus a copy glyph, written as \u escapes to keep this file ASCII-only.
" Override with plain letters -- let g:neodiff_status_symbols = {'A': 'A', ...}
" -- or any glyphs; a status absent from the dict shows a blank cell.
let g:neodiff_status_symbols = get(g:, 'neodiff_status_symbols', {
    \ 'A': "\uf457", 'M': "\uf459", 'D': "\uf458",
    \ 'R': "\uf45a", 'C': "\uf0c5" })
