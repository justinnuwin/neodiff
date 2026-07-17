" ==============================================================================
" Hand-rolled headless functional tests for the neodiff plugin. Runs unchanged
" on vim and nvim. Drives the public neodiff#Setup() with fixture entries (empty
" 'setup', so no fugitive is needed) and asserts on the sidebar buffer contents,
" tab state, and neodiff#Title() output.
"
"   vim  -Nu ci/vimrc -es -S ci/run_functional.vim
"   nvim -Nu ci/vimrc --headless -S ci/run_functional.vim
"
" Exits 0 on success, 1 (via :cquit) with a report on any failure.
" ==============================================================================

source <sfile>:p:h/fixtures.vim

" Plain-letter status glyphs so column widths are 1 and assertions do not depend
" on Nerd Font glyph display widths. A wide, fixed screen keeps the title bar and
" stat column layout deterministic.
let g:neodiff_status_symbols = {'A': 'A', 'M': 'M', 'D': 'D', 'R': 'R', 'C': 'C'}
let g:neodiff_width = 52
set columns=120
set lines=40

let g:nd_failures = []

function! Assert(cond, msg) abort
    if !a:cond
        call add(g:nd_failures, a:msg)
    endif
endfunction

function! AssertEq(got, want, msg) abort
    call Assert(a:got ==# a:want,
        \ a:msg . ' -- got ' . string(a:got) . ', want ' . string(a:want))
endfunction

" ------------------------------------------------------------------------------
" Harness helpers
" ------------------------------------------------------------------------------

" Tear down all tab/window/buffer/autocmd/mapping state left by a prior case so
" the next neodiff#Setup starts from a clean editor.
function! NdReset() abort
    silent! autocmd! neodiff
    set tabline=
    set showtabline=1
    for l:key in ['gt', 'gT', '<C-h>', '<C-l>', '?']
        execute 'silent! nunmap ' . l:key
    endfor
    while tabpagenr('$') > 1
        silent! tabclose!
    endwhile
    silent! only!
    silent! %bwipeout!
    enew
endfunction

" Open one tab per entry (mirroring `vim -p file1 file2 ...`), then hand the
" entries to the plugin.
function! NdSetupCase(title, entries, refresh) abort
    call NdReset()
    let l:idx = 0
    for l:entry in a:entries
        if l:idx == 0
            execute 'edit ' . fnameescape(l:entry.file)
        else
            execute 'tabnew ' . fnameescape(l:entry.file)
        endif
        let l:idx += 1
    endfor
    call neodiff#Setup(a:title, a:entries, a:refresh)
endfunction

" Lines of the shared sidebar scratch buffer.
function! NdSidebar() abort
    let l:bufnr = bufnr('__neodiff__')
    return l:bufnr < 0 ? [] : getbufline(l:bufnr, 1, '$')
endfunction

" The trailing token of every tree line (a file name or a 'dir/' marker), in
" render order. Valid only for stat-free, unpinned fixtures, where each tree line
" ends in its node name; the header and blank spacer lines are skipped.
function! NdTokens() abort
    let l:tokens = []
    let l:linenr = 0
    for l:line in NdSidebar()
        let l:linenr += 1
        if l:linenr == 1 || l:line =~# '^\s*$'
            continue
        endif
        call add(l:tokens, matchstr(l:line, '\S\+$'))
    endfor
    return l:tokens
endfunction

" 1-based sidebar line number of the first line matching a:pattern, else -1.
function! NdFindLine(pattern) abort
    let l:linenr = 0
    for l:line in NdSidebar()
        let l:linenr += 1
        if l:line =~# a:pattern
            return l:linenr
        endif
    endfor
    return -1
endfunction

" neodiff_id tagged on each tab, in tab order.
function! NdTabIds() abort
    let l:ids = []
    for l:tabnr in range(1, tabpagenr('$'))
        call add(l:ids, gettabvar(l:tabnr, 'neodiff_id', -2))
    endfor
    return l:ids
endfunction

" Focus the sidebar window (or a content window) in the current tab; returns 0
" if none is found.
function! NdFocusFiletype(want_sidebar) abort
    for l:winnr in range(1, winnr('$'))
        let l:is_sidebar = getwinvar(l:winnr, '&filetype') ==# 'neodiff'
        if l:is_sidebar == a:want_sidebar
            execute l:winnr . 'wincmd w'
            return 1
        endif
    endfor
    return 0
endfunction

" Whether a sidebar window is present in the current tab.
function! NdHasSidebar() abort
    for l:winnr in range(1, winnr('$'))
        if getwinvar(l:winnr, '&filetype') ==# 'neodiff'
            return 1
        endif
    endfor
    return 0
endfunction

" Switch to the tab tagged with neodiff_id a:id.
function! NdGotoId(id) abort
    for l:tabnr in range(1, tabpagenr('$'))
        if gettabvar(l:tabnr, 'neodiff_id', -2) == a:id
            execute 'tabnext ' . l:tabnr
            return 1
        endif
    endfor
    return 0
endfunction

" Put the cursor on the sidebar line ending in a:name and trigger <CR> (the
" plugin's Select mapping). a:name must be the line's trailing token.
function! NdSelect(name) abort
    call NdFocusFiletype(1)
    let l:lnum = NdFindLine('\V' . escape(a:name, '\') . '\$')
    call cursor(l:lnum, 1)
    execute "normal \<CR>"
endfunction

" ------------------------------------------------------------------------------
" Cases
" ------------------------------------------------------------------------------

" Directories sort before files, both alphabetically, depth-first.
function! Test_tree_sort_order() abort
    let l:entries = [
        \ NdDiffEntry('src/main.c', '', 'M'),
        \ NdDiffEntry('src/app.c', '', 'M'),
        \ NdDiffEntry('README.md', '', 'M'),
        \ NdDiffEntry('src/util/log.c', '', 'A')]
    call NdSetupCase('Sort', l:entries, [])
    call AssertEq(NdTokens(),
        \ ['src/', 'util/', 'log.c', 'app.c', 'main.c', 'README.md'],
        \ 'tree render order')
endfunction

" A tree larger than 1.5 * &lines starts fully collapsed (top dirs only, '+'
" markers, no file leaves visible).
function! Test_collapse_threshold_collapsed() abort
    let l:save_lines = &lines
    set lines=10
    let l:entries = []
    for l:idx in range(25)
        call add(l:entries, NdDiffEntry(printf('d%02d/f.c', l:idx), '', 'M'))
    endfor
    call NdSetupCase('Collapsed', l:entries, [])
    let &lines = l:save_lines
    let l:tokens = NdTokens()
    call AssertEq(len(l:tokens), 25, 'collapsed: only top dirs shown')
    call Assert(NdFindLine('+ d00/') > 0, 'collapsed: d00 has a + marker')
    call Assert(NdFindLine('f\.c$') < 0, 'collapsed: no file leaf visible')
endfunction

" A tree that fits starts fully expanded (file leaves visible, '-' markers).
function! Test_collapse_threshold_expanded() abort
    let l:entries = []
    for l:idx in range(4)
        call add(l:entries, NdDiffEntry(printf('d%d/f.c', l:idx), '', 'M'))
    endfor
    call NdSetupCase('Expanded', l:entries, [])
    call Assert(NdFindLine('- d0/') > 0, 'expanded: d0 has a - marker')
    call Assert(NdFindLine('f\.c$') > 0, 'expanded: file leaf visible')
endfunction

" Selecting a directory line toggles it collapsed, then expanded again; the
" cursor stays on the toggled line.
function! Test_directory_toggle() abort
    let l:entries = [
        \ NdDiffEntry('src/a.c', '', 'M'),
        \ NdDiffEntry('src/b.c', '', 'M')]
    call NdSetupCase('Toggle', l:entries, [])
    call Assert(NdFindLine('a\.c$') > 0, 'toggle: children start visible')

    call NdSelect('src/')
    call Assert(NdFindLine('a\.c$') < 0, 'toggle: children hidden after collapse')
    call Assert(NdFindLine('+ src/') > 0, 'toggle: dir shows + when collapsed')

    call NdSelect('src/')
    call Assert(NdFindLine('a\.c$') > 0, 'toggle: children visible after expand')
endfunction

" Selecting a file jumps to the tab already showing its diff.
function! Test_select_to_tab() abort
    let l:entries = [
        \ NdDiffEntry('a.txt', '', 'M'),
        \ NdDiffEntry('b.txt', '', 'M'),
        \ NdDiffEntry('c.txt', '', 'M')]
    call NdSetupCase('Select', l:entries, [])
    call NdSelect('b.txt')
    call AssertEq(gettabvar(tabpagenr(), 'neodiff_id', -2), 1,
        \ 'select jumps to b.txt tab (id 1)')
endfunction

" Selecting a file whose tab was closed recreates the diff tab.
function! Test_reopen_after_close() abort
    let l:entries = [
        \ NdDiffEntry('a.txt', '', 'M'),
        \ NdDiffEntry('b.txt', '', 'M'),
        \ NdDiffEntry('c.txt', '', 'M')]
    call NdSetupCase('Reopen', l:entries, [])
    let l:before = tabpagenr('$')

    call NdGotoId(1)
    silent! tabclose!
    sleep 20m
    call AssertEq(tabpagenr('$'), l:before - 1, 'reopen: tab closed')
    call Assert(index(NdTabIds(), 1) < 0, 'reopen: id 1 gone after close')

    call NdSelect('b.txt')
    call AssertEq(tabpagenr('$'), l:before, 'reopen: tab recreated')
    call AssertEq(gettabvar(tabpagenr(), 'neodiff_id', -2), 1, 'reopen: back on id 1')
endfunction

" Quitting a diff window closes the whole managed tab (deferred via a timer).
function! Test_close_tab_on_quit() abort
    let l:entries = [
        \ NdDiffEntry('a.txt', '', 'M'),
        \ NdDiffEntry('b.txt', '', 'M'),
        \ NdDiffEntry('c.txt', '', 'M')]
    call NdSetupCase('Quit', l:entries, [])
    let l:before = tabpagenr('$')

    call NdGotoId(1)
    call NdFocusFiletype(0)
    silent! quit
    sleep 50m
    call AssertEq(tabpagenr('$'), l:before - 1, 'close-on-quit: tab removed')
    call Assert(index(NdTabIds(), 1) < 0, 'close-on-quit: id 1 gone')
endfunction

" Every stat string is left-aligned to the same display column.
function! Test_stat_alignment() abort
    let l:entries = [
        \ NdEntry('short.c', NdFile('short.c', ['x']), '', '+1 -1', 'M', 0),
        \ NdEntry('a-much-longer-name.c', NdFile('a-much-longer-name.c', ['x']),
        \     '', '+100 -200', 'M', 0),
        \ NdEntry('mid.c', NdFile('mid.c', ['x']), '', 'bin', 'M', 0)]
    call NdSetupCase('Stats', l:entries, [])
    let l:cols = []
    for l:line in NdSidebar()
        let l:stat = matchstr(l:line, '\%(+\d\+ -\d\+\|bin\)$')
        if l:stat !=# ''
            call add(l:cols, strdisplaywidth(l:line) - strdisplaywidth(l:stat))
        endif
    endfor
    call AssertEq(len(l:cols), 3, 'stat-align: three stats present')
    call Assert(min(l:cols) == max(l:cols), 'stat-align: stats share a column')
endfunction

" The title bar centers its text, pluralizes the tab count, and names the
" gt/gT (next/prev) files with wraparound.
function! Test_title_bar() abort
    call NdSetupCase('Solo', [NdDiffEntry('only.txt', '', 'M')], [])
    call Assert(neodiff#Title() =~# '(1 tab open)', 'title: singular tab count')

    let l:entries = [
        \ NdDiffEntry('a.txt', '', 'M'),
        \ NdDiffEntry('b.txt', '', 'M'),
        \ NdDiffEntry('c.txt', '', 'M')]
    call NdSetupCase('Trio', l:entries, [])
    call Assert(neodiff#Title() =~# '(3 tabs open)', 'title: plural tab count')

    call NdGotoId(1)
    let l:mid = neodiff#Title()
    call Assert(l:mid =~# 'gT <- a\.txt', 'title: prev is a.txt')
    call Assert(l:mid =~# 'c\.txt -> gt', 'title: next is c.txt')

    call NdGotoId(0)
    call Assert(neodiff#Title() =~# 'gT <- c\.txt', 'title: prev wraps to c.txt')
endfunction

" C-b toggles the sidebar, and the hidden state persists across tabs.
function! Test_sidebar_toggle() abort
    let l:entries = [
        \ NdDiffEntry('a.txt', '', 'M'),
        \ NdDiffEntry('b.txt', '', 'M')]
    call NdSetupCase('Sidebar', l:entries, [])
    call Assert(NdHasSidebar(), 'toggle: sidebar present initially')

    execute "normal \<C-b>"
    call Assert(!NdHasSidebar(), 'toggle: sidebar hidden after C-b')

    call NdGotoId(1)
    call Assert(!NdHasSidebar(), 'toggle: stays hidden after switching tabs')

    execute "normal \<C-b>"
    call Assert(NdHasSidebar(), 'toggle: sidebar restored after second C-b')
endfunction

" On :w, RefreshStats re-runs numstat and updates each entry's stat; a renamed
" file's `{old => new}` numstat path reduces to the entry label (NumstatNewPath).
function! Test_refresh_stats() abort
    let l:repo = g:nd_tmpdir . '/refreshrepo'
    call mkdir(l:repo, 'p')
    " gpgsign=false: the surrounding checkout may enable commit signing globally,
    " which would block on a passphrase prompt inside system().
    let l:git = 'git -C ' . shellescape(l:repo)
        \ . ' -c commit.gpgsign=false -c user.email=t@t -c user.name=t '
    call system(l:git . 'init -q')
    call system(l:git . 'commit -q --allow-empty -m init')
    call writefile(['a', 'b', 'c'], l:repo . '/mod.txt')
    call writefile(['keep'], l:repo . '/old.txt')
    call system(l:git . 'add -A')
    call system(l:git . 'commit -q -m base')
    " Stage a content change and a rename so `git diff --cached --numstat -M`
    " reports both a normal path and a `old => new` rename path.
    call writefile(['a', 'B', 'c', 'd'], l:repo . '/mod.txt')
    call system(l:git . 'add mod.txt')
    call system(l:git . 'mv old.txt new.txt')

    let l:refresh = ['git', '-C', l:repo, 'diff', '--cached', '-M', '--numstat']
    let l:entries = [
        \ NdEntry('mod.txt', l:repo . '/mod.txt', '', '', 'M', 0),
        \ NdEntry('new.txt', l:repo . '/new.txt', '', '', 'R', 0)]
    call NdSetupCase('Refresh', l:entries, l:refresh)
    call NdFocusFiletype(1)
    doautocmd BufWritePost

    call Assert(NdFindLine('mod\.txt.*+2 -1$') > 0, 'refresh: mod.txt stat updated')
    call Assert(NdFindLine('new\.txt.*+0 -0$') > 0,
        \ 'refresh: renamed new.txt stat resolved via NumstatNewPath')
endfunction

" ------------------------------------------------------------------------------
" Driver
" ------------------------------------------------------------------------------

let s:cases = [
    \ 'Test_tree_sort_order',
    \ 'Test_collapse_threshold_collapsed',
    \ 'Test_collapse_threshold_expanded',
    \ 'Test_directory_toggle',
    \ 'Test_select_to_tab',
    \ 'Test_reopen_after_close',
    \ 'Test_close_tab_on_quit',
    \ 'Test_stat_alignment',
    \ 'Test_title_bar',
    \ 'Test_sidebar_toggle',
    \ 'Test_refresh_stats']

for s:case in s:cases
    try
        execute 'call ' . s:case . '()'
    catch
        call add(g:nd_failures, s:case . ' threw: ' . v:exception . ' @ ' . v:throwpoint)
    endtry
endfor

if empty(g:nd_failures)
    echo 'PASS: ' . len(s:cases) . ' cases'
    qall!
else
    echo 'FAIL: ' . len(g:nd_failures) . ' assertion(s)'
    for s:msg in g:nd_failures
        echo '  - ' . s:msg
    endfor
    cquit 1
endif
