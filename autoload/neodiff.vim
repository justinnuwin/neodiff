" ==============================================================================
" neodiff (autoload) - implementation for an improved diff viewer.
"
" Loaded lazily the first time neodiff#Setup is called (see plugin/neodiff.vim)
" ==============================================================================

let s:bufname = '__neodiff__'

" Text shown in the title bar (before the tab count).
let s:title = ''
" List of {'label', 'file', 'setup', 'stat', ['status', 'pinned']}
" The index is the stable tab identifier. Pinned entries render above the diff
" tree (see s:Rebuild). A pinned label without a '/' is a flat line, while one
" with a '/' is a collapsible subtree.
let s:entries = []
" Argv list for the numstat refresh command (empty = no refresh).
let s:refresh = []
" Nested node {'dirs': {name: node}, 'files': {name: id}, 'name', 'path'} built
" from the unpinned (diff) entries.
let s:tree = {}
" Same node shape as s:tree, built from pinned entries whose label has a '/',
" i.e. the pinned folder(s) shown above the diff tree.
let s:pinned_tree = {}
" Set (dict used as a set) of directory paths that are closed.
let s:collapsed = {}
" {lnum: {'type':'dir','path'} | {'type':'file','id'}}.
let s:line_to_node = {}
" Entry ids in sidebar (tree-display) order: pinned flat entries, then the
" pinned subtree, then the diff tree, each depth-first (dirs before files).
" gt/gT and the title bar walk this, so navigation matches the visible tree,
" not tab order.
let s:nav_order = []
" Tab ids queued for deferred close (see s:OnQuitPre).
let s:pending_close = []
" Whether the sidebar is currently toggled hidden; TabEnter honors this so the
" sidebar stays hidden across tabs until toggled back (see s:ToggleSidebar).
let s:sidebar_hidden = 0

function! s:NewNode(name, path) abort
    return {'dirs': {}, 'files': {}, 'name': a:name, 'path': a:path}
endfunction

" Total number of directory and file nodes when the tree is fully expanded.
function! s:CountNodes(node) abort
    let l:count = len(keys(a:node.files))
    for l:dir in values(a:node.dirs)
        let l:count += 1 + s:CountNodes(l:dir)
    endfor
    return l:count
endfunction

" Mark every directory in the tree as collapsed.
function! s:CollapseAll(node) abort
    for l:dir in values(a:node.dirs)
        let s:collapsed[l:dir.path] = 1
        call s:CollapseAll(l:dir)
    endfor
endfunction

" Insert entry a:id into tree a:root by splitting its label on '/', creating
" intermediate directory nodes as needed; the leaf stores the entry's stable id.
function! s:InsertEntry(root, label, id) abort
    let l:parts = split(a:label, '/')
    let l:node = a:root
    let l:part_index = 0
    while l:part_index < len(l:parts) - 1
        let l:part = l:parts[l:part_index]
        if !has_key(l:node.dirs, l:part)
            let l:path = l:node.path ==# '' ? l:part : l:node.path . '/' . l:part
            let l:node.dirs[l:part] = s:NewNode(l:part, l:path)
        endif
        let l:node = l:node.dirs[l:part]
        let l:part_index += 1
    endwhile
    if !empty(l:parts)
        let l:node.files[l:parts[-1]] = a:id
    endif
endfunction

" Append a node's file-leaf ids in depth-first order -- matching s:BuildLines.
" This ignores collapse state, so every file is visited regardless of fold.
function! s:CollectLeaves(node, ids) abort
    for l:name in sort(keys(a:node.dirs))
        call s:CollectLeaves(a:node.dirs[l:name], a:ids)
    endfor
    for l:name in sort(keys(a:node.files))
        call add(a:ids, a:node.files[l:name])
    endfor
endfunction

" Build s:nav_order: the entry ids in the same top-to-bottom order the sidebar
" renders them as:
" * pinned flat entries
" * pinned subtree
" * diff tree
" Navigation and rendering order are both depth-first.
function! s:BuildNavOrder() abort
    let s:nav_order = []
    let l:id = 0
    while l:id < len(s:entries)
        if get(s:entries[l:id], 'pinned', 0) && stridx(s:entries[l:id].label, '/') < 0
            call add(s:nav_order, l:id)
        endif
        let l:id += 1
    endwhile
    call s:CollectLeaves(s:pinned_tree, s:nav_order)
    call s:CollectLeaves(s:tree, s:nav_order)
endfunction

" Build the directory trees from the entry labels. There are 2 trees:
" * s:tree - The 'main' diff treenp
" * s:pinned_tree - A tree of 'pinned' entries (shown before the 'main' tree);
"   these entries contain a '/'
" NOTE: Entries which are pinned and do not container a '/' (aka 'flat entries')
" are not present in either, s:Rebuild lists them directly.
function! s:BuildTree() abort
    let s:tree = s:NewNode('', '')
    let s:pinned_tree = s:NewNode('', '')
    let s:collapsed = {}

    let l:entry_id = 0
    while l:entry_id < len(s:entries)
        let l:label = s:entries[l:entry_id].label
        if get(s:entries[l:entry_id], 'pinned', 0)
            if stridx(l:label, '/') >= 0
                call s:InsertEntry(s:pinned_tree, l:label, l:entry_id)
            endif
        else
            call s:InsertEntry(s:tree, l:label, l:entry_id)
        endif
        let l:entry_id += 1
    endwhile

    " Expand everything when the fully expanded diff tree fits within 150% of the
    " screen height; otherwise start with all directories collapsed. The pinned
    " subtree is small and always starts expanded.
    if s:CountNodes(s:tree) >= float2nr(1.5 * &lines)
        call s:CollapseAll(s:tree)
    endif

    call s:BuildNavOrder()
endfunction

" Window number of the sidebar in the current tab, or -1 if it is absent.
function! s:SidebarWinnr() abort
    let l:winnr = 1
    while l:winnr <= winnr('$')
        if getwinvar(l:winnr, '&filetype') ==# 'neodiff'
            return l:winnr
        endif
        let l:winnr += 1
    endwhile
    return -1
endfunction

function! s:SetupSyntax() abort
    syntax clear
    syntax match neodiffHeader /\%1l.*/
    syntax match neodiffDir /^.*\/$/
    syntax match neodiffStat / +\d\+ -\d\+$/ contains=neodiffAdd,neodiffDel
    syntax match neodiffAdd /+\d\+/ contained
    syntax match neodiffDel /-\d\+/ contained
    syntax match neodiffBin / bin$/
    " Color each far-left status glyph by its status. Built from the configured
    " symbols so an override recolors correctly; each glyph anchors at column 1
    " (only file lines carry one -- dirs/meta lines start with a blank cell).
    let l:status_hl = {'A': 'NeodiffStatusAdd', 'M': 'NeodiffStatusMod',
        \ 'D': 'NeodiffStatusDel', 'R': 'NeodiffStatusRen', 'C': 'NeodiffStatusCopy'}
    for l:st in keys(g:neodiff_status_symbols)
        let l:sym = g:neodiff_status_symbols[l:st]
        if l:sym ==# '' || !has_key(l:status_hl, l:st)
            continue
        endif
        execute 'syntax match ' . l:status_hl[l:st] . ' /^' . escape(l:sym, '/\.*$^~[]') . '/'
    endfor
    highlight default link neodiffHeader Title
    highlight default link neodiffDir Directory
    highlight default link neodiffBin Comment
    highlight neodiffAdd ctermfg=green guifg=#58e37b
    highlight neodiffDel ctermfg=red guifg=#ff5555
    highlight NeodiffStatusAdd  ctermfg=green   guifg=#58e37b
    highlight NeodiffStatusMod  ctermfg=yellow  guifg=#fac357
    highlight NeodiffStatusDel  ctermfg=red     guifg=#ff5555
    highlight NeodiffStatusRen  ctermfg=magenta guifg=#c792ea
    highlight NeodiffStatusCopy ctermfg=cyan    guifg=#7fd8cf
endfunction

" The far-left status cell for a file: its configured symbol, right-padded to the
" column width. An empty status (dirs, pinned/meta lines) yields a blank cell.
function! s:StatusCell(status, width) abort
    let l:sym = get(g:neodiff_status_symbols, a:status, '')
    let l:pad = a:width - strdisplaywidth(l:sym)
    return l:sym . repeat(' ', l:pad > 0 ? l:pad : 0)
endfunction

" Append tree items (each {'text', 'node', ['stat'], ['status']}) for a node's
" children. Directories are listed (sorted) before files.
function! s:BuildLines(node, depth, items) abort
    let l:indent = repeat('  ', a:depth)
    for l:name in sort(keys(a:node.dirs))
        let l:child = a:node.dirs[l:name]
        let l:closed = has_key(s:collapsed, l:child.path)
        let l:marker = l:closed ? '+' : '-'
        call add(a:items, {'text': l:indent . l:marker . ' ' . l:name . '/',
            \ 'node': {'type': 'dir', 'path': l:child.path}})
        if !l:closed
            call s:BuildLines(l:child, a:depth + 1, a:items)
        endif
    endfor
    for l:name in sort(keys(a:node.files))
        let l:file_id = a:node.files[l:name]
        call add(a:items, {'text': l:indent . '  ' . l:name,
            \ 'stat': get(s:entries[l:file_id], 'stat', ''),
            \ 'status': get(s:entries[l:file_id], 'status', ''),
            \ 'node': {'type': 'file', 'id': l:file_id}})
    endfor
endfunction

" Rewrite the sidebar buffer contents. Must run with the sidebar as the current
" window; leaves the cursor untouched. Change stats are aligned into a single
" column (just past the longest file name) so they are easy to scan.
function! s:Rebuild() abort
    let s:line_to_node = {}
    let l:items = []
    call s:BuildLines(s:tree, 0, l:items)

    " Far-left status column: width is the widest configured symbol. Every tree
    " and pinned line is prefixed with a status cell (the file's symbol, or blank
    " for dirs and meta lines) so the tree aligns beneath the leftmost glyph.
    let l:sym_width = 1
    for l:sym in values(g:neodiff_status_symbols)
        let l:sym_width = max([l:sym_width, strdisplaywidth(l:sym)])
    endfor
    let l:blank_cell = repeat(' ', l:sym_width) . ' '
    for l:item in l:items
        let l:item.text = (l:item.node.type ==# 'file'
            \ ? s:StatusCell(get(l:item, 'status', ''), l:sym_width) . ' '
            \ : l:blank_cell) . l:item.text
    endfor

    let l:max_name_width = 0
    let l:max_stat_width = 0
    for l:item in l:items
        if get(l:item, 'stat', '') !=# ''
            let l:max_name_width = max([l:max_name_width, strdisplaywidth(l:item.text)])
            let l:max_stat_width = max([l:max_stat_width, strdisplaywidth(l:item.stat)])
        endif
    endfor
    let l:stat_col = l:max_name_width + 2
    let l:max_stat_col = g:neodiff_width - l:max_stat_width - 1
    if l:stat_col > l:max_stat_col | let l:stat_col = l:max_stat_col | endif
    if l:stat_col < 1 | let l:stat_col = 1 | endif

    " Line 1 is the pane title; the tree follows after a blank spacer. Both are
    " non-selectable (absent from s:line_to_node). The '(? for help)' hint is
    " right-aligned to the sidebar width (s:ShowHelp echoes the key legend).
    let l:hint = '(? for help)'
    let l:head_pad = g:neodiff_width - strdisplaywidth('neodiff') - strdisplaywidth(l:hint)
    let l:lines = ['neodiff' . repeat(' ', l:head_pad > 1 ? l:head_pad : 1) . l:hint, '']

    " Pinned section, above the diff tree: flat pinned entries first, in tab
    " order, then the pinned subtree, then a blank spacer. All stay selectable.
    " Pinned lines get a blank status cell so they align with the diff tree.
    let l:pinned = 0
    let l:pin_id = 0
    while l:pin_id < len(s:entries)
        if get(s:entries[l:pin_id], 'pinned', 0) && stridx(s:entries[l:pin_id].label, '/') < 0
            call add(l:lines, l:blank_cell . s:entries[l:pin_id].label)
            let s:line_to_node[len(l:lines)] = {'type': 'file', 'id': l:pin_id}
            let l:pinned += 1
        endif
        let l:pin_id += 1
    endwhile
    let l:pinned_items = []
    call s:BuildLines(s:pinned_tree, 0, l:pinned_items)
    for l:item in l:pinned_items
        call add(l:lines, l:blank_cell . l:item.text)
        let s:line_to_node[len(l:lines)] = l:item.node
        let l:pinned += 1
    endfor
    if l:pinned > 0
        call add(l:lines, '')
    endif

    for l:item in l:items
        let l:text = l:item.text
        if get(l:item, 'stat', '') !=# ''
            let l:pad = l:stat_col - strdisplaywidth(l:text)
            let l:text .= repeat(' ', l:pad > 0 ? l:pad : 1) . l:item.stat
        endif
        call add(l:lines, l:text)
        let s:line_to_node[len(l:lines)] = l:item.node
    endfor

    setlocal modifiable
    silent %delete _
    call setline(1, l:lines)
    setlocal nomodifiable
endfunction

" Refresh the sidebar in the current tab and park the cursor on the entry for
" the tab currently in view.
function! s:Render() abort
    let l:sidebar_winnr = s:SidebarWinnr()
    if l:sidebar_winnr == -1
        return
    endif

    let l:prev_win = win_getid()
    let l:current_id = gettabvar(tabpagenr(), 'neodiff_id', -2)
    execute l:sidebar_winnr . 'wincmd w'
    call s:Rebuild()

    for l:linenr in keys(s:line_to_node)
        let l:node = s:line_to_node[l:linenr]
        if l:node.type ==# 'file' && l:node.id == l:current_id
            call cursor(str2nr(l:linenr), 1)
            break
        endif
    endfor

    call win_gotoid(l:prev_win)
endfunction

function! s:OpenSidebar() abort
    let l:content_win = win_getid()

    execute 'topleft vsplit'
    if exists('s:bufnr') && bufexists(s:bufnr)
        execute 'buffer ' . s:bufnr
    else
        execute 'edit ' . fnameescape(s:bufname)
        let s:bufnr = bufnr('%')
    endif
    execute 'vertical resize ' . g:neodiff_width

    setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
    setlocal nonumber norelativenumber nolist nowrap nospell
    setlocal signcolumn=no foldcolumn=0
    setlocal cursorline winfixwidth
    setlocal filetype=neodiff
    call s:SetupSyntax()
    nnoremap <buffer> <silent> <CR> :call <SID>Select()<CR>
    nnoremap <buffer> <silent> o :call <SID>Select()<CR>
    nnoremap <buffer> <silent> <LeftRelease> :call <SID>Select()<CR>

    call s:Render()
    call win_gotoid(l:content_win)
    " Force the diff panes back to equal width now that the fixed-width sidebar
    " exists (winfixwidth keeps the sidebar itself out of the equalization).
    wincmd =
endfunction

" Focus the sidebar window in the current tab, if present.
function! s:FocusSidebar() abort
    let l:winnr = s:SidebarWinnr()
    if l:winnr != -1
        execute l:winnr . 'wincmd w'
    endif
endfunction

" Close the sidebar window in the current tab, if present, then rebalance the
" remaining diff panes.
function! s:CloseSidebar() abort
    let l:winnr = s:SidebarWinnr()
    if l:winnr != -1
        execute l:winnr . 'close'
        wincmd =
    endif
endfunction

" Ensure the sidebar exists in the current tab and its contents are current,
" then rebalance the diff panes (winfixwidth keeps the sidebar's width). While
" the sidebar is toggled hidden, keep it closed instead (dropping any that
" lingers in a tab not yet re-entered since hiding).
function! s:EnsureSidebar() abort
    if s:sidebar_hidden
        call s:CloseSidebar()
        return
    endif
    if s:SidebarWinnr() == -1
        call s:OpenSidebar()
    endif
    call s:Render()
    wincmd =
endfunction

" Toggle the sidebar's visibility. The state persists in s:sidebar_hidden so
" TabEnter (s:EnsureSidebar) honors it in every tab, not just the current one.
function! s:ToggleSidebar() abort
    let s:sidebar_hidden = !s:sidebar_hidden
    if s:sidebar_hidden
        call s:CloseSidebar()
    else
        call s:EnsureSidebar()
    endif
endfunction

" Diff appearance for the managed diff panes. NOTE: for Neovim only.
" This function relies on a full-cell fill character and per-window highlight
" remaps (winhighlight). Behaviorally this achieves:
"   - Deleted hunks show as filler lines in the opposite pane; instead of a
"     solid red block, render them on the normal background with a muted gray
"     slashed hatch, so a deletion reads as absent content.
"   - Within a changed line, the differing span is tinted per pane by
"     s:SetupDiffPaneColors (removed text red on the left, added text green on
"     the right); the groups it maps DiffText onto are defined here.
function! s:SetupDiffView() abort
    if !has('nvim')
        return
    endif
    " U+2571 is a full-cell diagonal that tiles into a continuous slash across
    " the filler line. Written as an escape to keep the source ASCII-only.
    execute "set fillchars+=diff:\u2571"
    highlight DiffDelete cterm=none ctermfg=240 ctermbg=none gui=none guifg=#585858 guibg=bg
    " Whole added/removed lines (DiffAdd): red on the older (left) pane where the
    " line is a removal, green on the newer (right) pane where it is an addition.
    highlight NeodiffDiffLineDel cterm=bold gui=bold ctermfg=none ctermbg=52 guifg=fg guibg=#5f0000
    highlight NeodiffDiffLineAdd cterm=bold gui=bold ctermfg=none ctermbg=22 guifg=fg guibg=#005f00
    " Changed-line background (DiffChange): a very muted red/green wash (not the
    " default blue) so the changed-text span below stands out against it. 52/22
    " are the darkest red/green in the 256-color cube, which termguicolors=false
    " limits us to here.
    highlight NeodiffDiffChangeDel cterm=none gui=none ctermfg=none ctermbg=52 guifg=fg guibg=#3a1e1e
    highlight NeodiffDiffChangeAdd cterm=none gui=none ctermfg=none ctermbg=22 guifg=fg guibg=#1e3a1e
    " Changed-text spans within a changed line (DiffText): a brighter red/green
    " on top of the DiffChange line background.
    highlight NeodiffDiffTextDel cterm=bold gui=bold ctermfg=none ctermbg=88 guifg=fg guibg=#870000
    highlight NeodiffDiffTextAdd cterm=bold gui=bold ctermfg=none ctermbg=28 guifg=fg guibg=#008700
endfunction

" Tint each diff pane per side: the older (left) pane in red, the newer (right)
" pane in green -- both the whole added/removed lines (DiffAdd) and the changed
" span within a changed line (DiffText). Done with a per-window highlight remap
" (winhighlight), so it is neovim only. Must run while
" the two diff panes are the only windows in the tab (before the sidebar opens),
" so screen position identifies left vs right unambiguously.
function! s:SetupDiffPaneColors() abort
    if !has('nvim')
        return
    endif
    let l:diff_wins = []
    for l:nr in range(1, winnr('$'))
        if getwinvar(l:nr, '&diff')
            call add(l:diff_wins, [l:nr, win_screenpos(l:nr)[1]])
        endif
    endfor
    if len(l:diff_wins) < 2
        return
    endif
    call sort(l:diff_wins, {a, b -> a[1] - b[1]})
    call setwinvar(l:diff_wins[0][0], '&winhighlight',
        \ 'DiffAdd:NeodiffDiffLineDel,DiffChange:NeodiffDiffChangeDel,DiffText:NeodiffDiffTextDel')
    call setwinvar(l:diff_wins[-1][0], '&winhighlight',
        \ 'DiffAdd:NeodiffDiffLineAdd,DiffChange:NeodiffDiffChangeAdd,DiffText:NeodiffDiffTextAdd')
endfunction

" Turn the current tab into entry a:id's diff: run its setup, tag it, match diff
" folds on both panes, and open the sidebar.
function! s:PrepareTab(id) abort
    call settabvar(tabpagenr(), 'neodiff_id', a:id)
    if s:entries[a:id].setup !=# ''
        " silent! swallows the git stderr fugitive surfaces for added/deleted
        " files (e.g. "fatal: path ... does not exist in <sha>"); with many tabs
        " these otherwise pile up and flicker during setup. The try/catch in the
        " setup already handles the Vim-level exception.
        silent! execute s:entries[a:id].setup
    endif
    " signcolumn=no hides gitgutter's gutter within the diff panes only -- the
    " side-by-side diff already shows added/removed lines, so the gutter is
    " redundant here (and coc diagnostics are disabled for this session).
    silent! windo if &diff | setlocal foldmethod=diff foldlevel=0 signcolumn=no | endif
    call s:SetupDiffPaneColors()
    call s:OpenSidebar()
endfunction

" Drop fugitive's blame maps (<CR> and double-click, both bound to :Git blame) in
" the current fugitive diff buffer. Blame is out of scope for now; without this
" <CR> would replace a diff pane with the blame view. Fugitive re-applies these
" maps every time the buffer is entered, so this runs from a BufEnter autocmd
" (registered after fugitive's, so it wins) rather than once at setup. Guarded to
" managed tabs so fugitive buffers outside a neodiff session are left alone.
function! s:DisableBlame() abort
    if !exists('t:neodiff_id')
        return
    endif
    silent! nunmap <buffer> <CR>
    silent! nunmap <buffer> <2-LeftMouse>
endfunction

" Escape '%' so it is not interpreted as a tabline field (it renders literally).
function! s:EscapePercent(text) abort
    return substitute(a:text, '%', '%%', 'g')
endfunction

" Render the title bar on a gray background: the previous file (gT target) at
" the far left, the diff/show description plus a live tab count centered, and
" the next file (gt target) at the far right.
"
" Vim's '%=' cannot true-center between two side blocks of unequal width, so the
" title drifts as the prev/next names change per tab. Instead we center the
" title against the full window width and pad the gaps ourselves. On a window
" too narrow to fit the side blocks without touching the centered title, we drop
" them. strwidth measures the raw text (the single '%#..#' highlight token is
" prepended only at return, so it never distorts the width math).
function! neodiff#Title() abort
    let l:tab_count = tabpagenr('$')
    let l:title = s:title . ' (' . l:tab_count . ' tab' . (l:tab_count == 1 ? '' : 's') . ' open)'
    let l:hl = '%#NeodiffTitleBar#'
    let l:columns = &columns
    let l:title_width = strwidth(l:title)
    let l:title_start = (l:columns - l:title_width) / 2
    if l:title_start < 0 | let l:title_start = 0 | endif

    if l:tab_count <= 1
        return l:hl . repeat(' ', l:title_start) . s:EscapePercent(l:title)
    endif

    " Prev/next follow the tree-display order (s:nav_order), matching gt/gT.
    let l:n = len(s:nav_order)
    let l:current_id = gettabvar(tabpagenr(), 'neodiff_id', -2)
    let l:idx = index(s:nav_order, l:current_id)
    if l:n == 0 || l:idx < 0
        return l:hl . repeat(' ', l:title_start) . s:EscapePercent(l:title)
    endif
    let l:prev_id = s:nav_order[(l:idx - 1 + l:n) % l:n]
    let l:next_id = s:nav_order[(l:idx + 1) % l:n]
    let l:prev_name = fnamemodify(s:entries[l:prev_id].label, ':t')
    let l:next_name = fnamemodify(s:entries[l:next_id].label, ':t')
    let l:left = ' gT <- ' . l:prev_name
    let l:right = l:next_name . ' -> gt '
    let l:left_width = strwidth(l:left)
    let l:right_width = strwidth(l:right)

    " Drop the side blocks if they would overlap the centered title.
    if l:title_start < l:left_width || l:title_start + l:title_width > l:columns - l:right_width
        return l:hl . repeat(' ', l:title_start) . s:EscapePercent(l:title)
    endif

    let l:gap_left = l:title_start - l:left_width
    let l:gap_right = l:columns - l:right_width - l:title_start - l:title_width
    return l:hl . s:EscapePercent(l:left) . repeat(' ', l:gap_left)
        \ . s:EscapePercent(l:title) . repeat(' ', l:gap_right) . s:EscapePercent(l:right)
endfunction

function! s:SetupTitleBar() abort
    highlight NeodiffTitleBar cterm=bold gui=bold ctermbg=240 ctermfg=253 guibg=#585858 guifg=#dadada
    set showtabline=2
    set tabline=%!neodiff#Title()
endfunction

" Reduce a `--numstat -M` rename path to its post-rename form so it matches the
" entry label: 'a/{b => c}/d' -> 'a/c/d', and a brace-less 'old => new' -> 'new'.
" (The refresh runs without -z, since Vim's system() cannot carry NUL bytes.)
function! s:NumstatNewPath(raw) abort
    if a:raw !~# ' => '
        return a:raw
    endif
    let l:p = substitute(a:raw, '{.\{-} => \(.\{-}\)}', '\1', '')
    return substitute(l:p, '^.\{-} => ', '', '')
endfunction

" Re-run the numstat command, update every entry's stat, and refresh the
" sidebar. Registered only when a refresh command was supplied (working-tree
" diffs), via the BufWritePost autocmd in neodiff#Setup.
function! s:RefreshStats() abort
    let l:numstat_lines = systemlist(join(map(copy(s:refresh), 'shellescape(v:val)'), ' '))
    if v:shell_error
        return
    endif
    let l:stat_by_path = {}
    for l:line in l:numstat_lines
        let l:parts = split(l:line, '\t')
        if len(l:parts) >= 3
            let l:stat_by_path[s:NumstatNewPath(l:parts[2])] = l:parts[0] ==# '-'
                \ ? 'bin' : '+' . l:parts[0] . ' -' . l:parts[1]
        endif
    endfor
    " Only the change counts refresh on save; each entry's git status is fixed.
    for l:entry in s:entries
        let l:entry.stat = get(l:stat_by_path, l:entry.label, '')
    endfor
    call s:Render()
endfunction

" Switch to the tab holding entry a:id, recreating its diff tab if it was
" closed.
function! s:GotoOrReopen(id) abort
    for l:tabnr in range(1, tabpagenr('$'))
        if gettabvar(l:tabnr, 'neodiff_id', -2) == a:id
            execute 'tabnext ' . l:tabnr
            return
        endif
    endfor

    execute '$tabnew ' . fnameescape(s:entries[a:id].file)
    call s:PrepareTab(a:id)
endfunction

" Move to the file a:delta steps from the current tab in s:nav_order (wrapping),
" reopening its diff tab if it was closed. Bound to gt/gT so tab navigation
" follows the visible tree rather than physical tab order. Preserves which pane
" is focused: stepping from the sidebar lands on the destination tab's sidebar,
" not its diff, so tree navigation does not drop the cursor into the diff.
function! s:NavStep(delta) abort
    if empty(s:nav_order)
        return
    endif
    let l:on_sidebar = &filetype ==# 'neodiff'
    let l:current_id = gettabvar(tabpagenr(), 'neodiff_id', -2)
    let l:idx = index(s:nav_order, l:current_id)
    if l:idx < 0
        let l:idx = 0
    endif
    let l:next = (l:idx + a:delta) % len(s:nav_order)
    if l:next < 0
        let l:next += len(s:nav_order)
    endif
    call s:GotoOrReopen(s:nav_order[l:next])
    if l:on_sidebar
        call s:FocusSidebar()
    endif
endfunction

" Toggle a directory, or jump to (reopening if needed) the file under the
" cursor.
function! s:Select() abort
    let l:linenr = line('.')
    if !has_key(s:line_to_node, l:linenr)
        return
    endif

    let l:node = s:line_to_node[l:linenr]
    if l:node.type ==# 'dir'
        if has_key(s:collapsed, l:node.path)
            call remove(s:collapsed, l:node.path)
        else
            let s:collapsed[l:node.path] = 1
        endif
        call s:Rebuild()
        call cursor(l:linenr, 1)
    else
        call s:GotoOrReopen(l:node.id)
    endif
endfunction

" Echo the key legend (bound to '?' in every tab). The sidebar header advertises
" this as '(? for help)' so the full list stays out of the always-on UI.
function! s:ShowHelp() abort
    echo join([
        \ 'neodiff keys:',
        \ '  [c  ]c    previous / next hunk',
        \ '  gt  gT    previous / next file',
        \ '  C-h C-l   focus pane left / right',
        \ '  C-b       toggle the sidebar',
        \ '  C-p       search symbols in the changed files',
        \ ], "\n")
endfunction

function! s:DrainClose(timer) abort
    while !empty(s:pending_close)
        let l:target_id = remove(s:pending_close, 0)
        for l:tabnr in range(1, tabpagenr('$'))
            if gettabvar(l:tabnr, 'neodiff_id', -2) == l:target_id
                " Closing the only diff tab leaves nothing to show, so quit Vim
                " rather than error (E784) trying to close the last tab page.
                if tabpagenr('$') <= 1
                    qall
                else
                    execute l:tabnr . 'tabclose'
                endif
                break
            endif
        endfor
    endwhile
endfunction

" On :quit inside a diff window (not the sidebar) of a managed tab, close the
" whole tab. Deferred via a timer because a window cannot be closed from within
" QuitPre while the original :quit is still unwinding.
function! s:OnQuitPre() abort
    if !exists('t:neodiff_id') || &filetype ==# 'neodiff'
        return
    endif
    call add(s:pending_close, t:neodiff_id)
    call timer_start(0, function('s:DrainClose'))
endfunction

" Collect the symbols (tags) across the changed files in the current view, using
" Universal/Exuberant Ctags. Returns a list of
" {'name','id','file','line','kind'} where id is the owning entry's stable id.
" Only unpinned entries whose working-tree file is readable are scanned (deleted
" files and meta/pinned entries have no such file). Empty if ctags is missing,
" fails, or finds nothing. Public so a custom picker can reuse it.
function! neodiff#CollectSymbols() abort
    if !executable('ctags')
        return []
    endif
    let l:files = []
    let l:id_by_file = {}
    let l:entry_id = 0
    while l:entry_id < len(s:entries)
        let l:entry = s:entries[l:entry_id]
        if !get(l:entry, 'pinned', 0) && filereadable(l:entry.file)
            call add(l:files, l:entry.file)
            let l:id_by_file[l:entry.file] = l:entry_id
        endif
        let l:entry_id += 1
    endwhile
    if empty(l:files)
        return []
    endif

    " --excmd=number puts a line number (not a search pattern) in the address
    " field; -f - writes the tab-separated tags to stdout in definition order.
    let l:cmd = 'ctags -f - --excmd=number --sort=no '
        \ . join(map(copy(l:files), 'shellescape(v:val)'), ' ')
    let l:tag_lines = systemlist(l:cmd)
    if v:shell_error
        return []
    endif

    let l:symbols = []
    for l:tag_line in l:tag_lines
        if l:tag_line[0] ==# '!'
            continue        " ctags pseudo-tag header
        endif
        let l:parts = split(l:tag_line, '\t')
        if len(l:parts) < 3 || !has_key(l:id_by_file, l:parts[1])
            continue
        endif
        call add(l:symbols, {
            \ 'name': l:parts[0],
            \ 'id': l:id_by_file[l:parts[1]],
            \ 'file': l:parts[1],
            \ 'line': str2nr(matchstr(l:parts[2], '\d\+')),
            \ 'kind': len(l:parts) >= 4 ? l:parts[3] : ''})
    endfor
    return l:symbols
endfunction

" Jump to a symbol: switch to its file's tab (reopening if closed), focus the
" working-tree (rightmost) diff pane, and move to the symbol's line. The line is
" from the working-tree file, so it is exact for working-tree diffs and a close
" approximation for revision diffs where that file has since moved.
function! s:JumpToSymbol(symbol) abort
    call s:GotoOrReopen(a:symbol.id)
    let l:diff_wins = []
    for l:nr in range(1, winnr('$'))
        if getwinvar(l:nr, '&diff')
            call add(l:diff_wins, [l:nr, win_screenpos(l:nr)[1]])
        endif
    endfor
    if !empty(l:diff_wins)
        call sort(l:diff_wins, {left, right -> left[1] - right[1]})
        execute l:diff_wins[-1][0] . 'wincmd w'
    endif
    if a:symbol.line > 0
        execute a:symbol.line
        normal! zz
    endif
endfunction

" Fallback picker (no fzf): a numbered inputlist.
function! s:InputlistSymbols(symbols) abort
    let l:choices = ['Select a symbol:']
    let l:index = 0
    for l:symbol in a:symbols
        call add(l:choices, printf('%d. %s  (%s:%d)', l:index + 1, l:symbol.name,
            \ fnamemodify(l:symbol.file, ':t'), l:symbol.line))
        let l:index += 1
    endfor
    let l:pick = inputlist(l:choices)
    if l:pick >= 1 && l:pick <= len(a:symbols)
        call s:JumpToSymbol(a:symbols[l:pick - 1])
    endif
endfunction

" fzf sink: the selected source line is prefixed with the symbol's index.
function! s:FzfSymbolSink(line) abort
    let l:index = str2nr(matchstr(a:line, '^\d\+'))
    if l:index >= 0 && l:index < len(s:fzf_symbols)
        call s:JumpToSymbol(s:fzf_symbols[l:index])
    endif
endfunction

" fzf picker (when fzf.vim is installed). Each source line hides a leading index
" column (--with-nth=2..) that the sink reads back.
function! s:FzfSymbols(symbols) abort
    let s:fzf_symbols = a:symbols
    let l:source = []
    let l:index = 0
    for l:symbol in a:symbols
        call add(l:source, l:index . "\t" . l:symbol.name . '  '
            \ . (l:symbol.kind ==# '' ? '' : '[' . l:symbol.kind . '] ')
            \ . fnamemodify(l:symbol.file, ':t') . ':' . l:symbol.line)
        let l:index += 1
    endfor
    call fzf#run(fzf#wrap({
        \ 'source': l:source,
        \ 'sink': function('s:FzfSymbolSink'),
        \ 'options': ['--with-nth=2..', '--delimiter=\t', '--prompt', 'Symbols> ']}))
endfunction

" Search the symbols in the current view and jump to the chosen one. Uses fzf
" when available, else a numbered inputlist; messages if ctags is missing or the
" view has no symbols. Bound to <C-p>.
function! s:SearchSymbols() abort
    if !executable('ctags')
        echohl WarningMsg
        echo 'neodiff: symbol search needs Universal/Exuberant Ctags (ctags not found)'
        echohl None
        return
    endif
    let l:symbols = neodiff#CollectSymbols()
    if empty(l:symbols)
        echo 'neodiff: no symbols found in the changed files'
        return
    endif
    if exists('*fzf#run')
        call s:FzfSymbols(l:symbols)
    else
        call s:InputlistSymbols(l:symbols)
    endif
endfunction

" Apply each entry's diff setup to its (already open) tab, tag the tab with its
" stable id, and add the sidebar. Then wire up the autocmds that keep the
" sidebar present and close tabs when their diff is closed.
function! neodiff#Setup(title, entries, refresh) abort
    let s:title = a:title
    let s:entries = a:entries
    let s:refresh = a:refresh
    let s:sidebar_hidden = 0
    call s:BuildTree()
    call s:SetupTitleBar()
    call s:SetupDiffView()

    " Be silent and show a loading message during per-tab setup.
    echo 'Preparing neodiff view (' . len(a:entries) . ' files)...'
    let l:start_tab = tabpagenr()
    let l:entry_id = 0
    while l:entry_id < len(a:entries)
        let l:tabnr = l:entry_id + 1
        execute 'tabnext ' . l:tabnr
        call s:PrepareTab(l:entry_id)
        let l:entry_id += 1
    endwhile

    augroup neodiff
        autocmd!
        autocmd TabEnter * call s:EnsureSidebar()
        autocmd QuitPre * call s:OnQuitPre()
        " Strip fugitive's blame maps whenever a fugitive diff buffer is entered
        " (fugitive re-adds them on entry, so a one-shot unmap does not stick).
        autocmd BufEnter fugitive://* call s:DisableBlame()
        " Rebalance the diff panes when the terminal/window size changes.
        autocmd VimResized * wincmd =
        " For working-tree diffs, re-derive the change stats whenever a buffer is
        " saved so the sidebar reflects edits made in the diff.
        if !empty(s:refresh)
            autocmd BufWritePost * call s:RefreshStats()
        endif
    augroup END

    " Walk the visible tree order (s:nav_order), not physical tab order, when
    " cycling files with gt/gT.
    nnoremap <silent> gt :call <SID>NavStep(1)<CR>
    nnoremap <silent> gT :call <SID>NavStep(-1)<CR>
    " Focus the pane to the left/right within the tab (tree | old | new); repeat
    " to cross panes (e.g. C-h twice from the new pane lands on the tree).
    nnoremap <silent> <C-h> <C-w>h
    nnoremap <silent> <C-l> <C-w>l
    " Toggle the global sidebar (hide it to view the diff full-width).
    nnoremap <silent> <C-b> :call <SID>ToggleSidebar()<CR>
    " Fuzzy-search symbols across the changed files and jump to one.
    nnoremap <silent> <C-p> :call <SID>SearchSymbols()<CR>
    " Echo the key legend from any tab, not just the sidebar.
    nnoremap <silent> ? :call <SID>ShowHelp()<CR>

    " Open on the first sidebar entry in tree-display order rather than whichever
    " tab Vim started on.
    if !empty(s:nav_order)
        call s:GotoOrReopen(s:nav_order[0])
    else
        execute 'tabnext ' . l:start_tab
    endif
    call s:Render()
    " Clear the "Preparing..." progress message now that setup is done. A bare
    " :redraw repaints but does not erase an echoed message; :echo '' does.
    redraw
    echo ''
endfunction
