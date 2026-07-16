" ==============================================================================
" Fugitive-dependent functional checks. Unlike ci/run_functional.vim (which uses
" empty setups and needs no fugitive), this renders a real diff view on the
" fixture repo, so it runs only in the CI container where fugitive and the
" fixture are present.
"
"   NEODIFF_FIXTURE=... nvim -Nu ci/vimrc --headless -S ci/integration.vim
"
" Exits 0 on success, 1 (via :cquit) on any failure.
" ==============================================================================

" Render the fixture diff view (cd's to $NEODIFF_FIXTURE, builds entries with
" real fugitive setups, calls neodiff#Setup) -- the same setup the golden dumps
" use.
source <sfile>:p:h/screendump_inner.vim

let g:failures = []

function! Assert(cond, msg) abort
    if !a:cond
        call add(g:failures, a:msg)
    endif
endfunction

" Focus a fugitive diff pane in the current tab (Setup lands on the modified
" file, whose two panes are both fugitive blobs).
let s:found = 0
for s:winnr in range(1, winnr('$'))
    if bufname(winbufnr(s:winnr)) =~# 'fugitive:' && getwinvar(s:winnr, '&diff')
        execute s:winnr . 'wincmd w'
        let s:found = 1
        break
    endif
endfor
call Assert(s:found, 'a fugitive diff pane is present')

" Blame is de-scoped: fugitive's <CR> / double-click blame maps must be gone from
" the diff panes (regression: <CR> opened :Git blame over the diff pane).
if s:found
    call Assert(maparg('<CR>', 'n') !~? 'blame',
        \ '<CR> no longer opens blame (got ' . string(maparg('<CR>', 'n')) . ')')
    call Assert(maparg('<2-LeftMouse>', 'n') !~? 'blame',
        \ 'double-click no longer opens blame')
endif

if empty(g:failures)
    echo 'integration: PASS'
    qall!
else
    for s:msg in g:failures
        echo 'integration FAIL: ' . s:msg
    endfor
    cquit 1
endif
