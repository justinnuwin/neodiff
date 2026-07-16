" ==============================================================================
" Sourced by the INNER editor (vim or nvim) running inside the outer editor's
" term_start. Renders a fixed neodiff view on the fixture repo at $NEODIFF_FIXTURE
" so the outer term_dumpwrite captures a deterministic screen.
"
" Determinism: statuslines/ruler are off (they would show the fixture path), the
" diffs use symbolic revisions (no commit SHAs on screen), and the fixture lives
" at a fixed path so nothing on screen varies run to run. Only the diff content,
" the neodiff sidebar, and the title bar remain -- all deterministic.
" ==============================================================================

set nomore noruler noshowcmd noshowmode laststatus=0
set shortmess+=F
set nonumber norelativenumber

let s:fixture = $NEODIFF_FIXTURE
execute 'cd ' . fnameescape(s:fixture)

" A forced-empty scratch pane, opposite a real blob, renders added all-green and
" deleted all-red (mirrors the shell launcher's _neodiff_diff_setup).
let s:scratch = 'setlocal buftype=nofile bufhidden=wipe noswapfile nomodifiable'

" One entry per git status against the fixture's HEAD vs HEAD~1. Setups use
" fugitive with symbolic revisions so no SHA reaches the screen. Stats are fixed
" here (the shell computes them from numstat in production); this exercises the
" sidebar's status glyphs, stat column, title bar, and the diff pane rendering.
let s:entries = [
    \ {'label': 'dir/new.c', 'file': s:fixture . '/dir/new.c',
    \  'stat': '+1 -0', 'status': 'A',
    \  'setup': 'try | Gedit HEAD:dir/new.c | diffthis | leftabove vnew | '
    \      . s:scratch . ' | diffthis | endtry'},
    \ {'label': 'dir/mod.c', 'file': s:fixture . '/dir/mod.c',
    \  'stat': '+1 -1', 'status': 'M',
    \  'setup': 'try | Gedit HEAD:dir/mod.c | Gvdiffsplit HEAD~1:dir/mod.c | endtry'},
    \ {'label': 'del.txt', 'file': s:fixture . '/del.txt',
    \  'stat': '+0 -1', 'status': 'D',
    \  'setup': 'try | Gedit HEAD~1:del.txt | diffthis | rightbelow vnew | '
    \      . s:scratch . ' | diffthis | endtry'},
    \ {'label': 'rename_dst.txt', 'file': s:fixture . '/rename_dst.txt',
    \  'stat': '+0 -0', 'status': 'R',
    \  'setup': 'try | Gedit HEAD:rename_dst.txt | Gvdiffsplit HEAD~1:rename_src.txt | endtry'}]

" Open one tab per entry (mirroring `vim -p`), then hand them to the plugin.
let s:idx = 0
for s:entry in s:entries
    if s:idx == 0
        execute 'edit ' . fnameescape(s:entry.file)
    else
        execute 'tabnew ' . fnameescape(s:entry.file)
    endif
    let s:idx += 1
endfor

call neodiff#Setup('Git Show fixture', s:entries, [])
