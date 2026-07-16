" ==============================================================================
" Golden screen-dump tests for neodiff's visual rendering (status glyph colors,
" the diff pane tinting, the deletion hatch, the gray title bar, fold rendering).
"
" Run by an OUTER Vim with +terminal: it launches each target editor (vim, nvim)
" inside term_start on the fixture view (ci/screendump_inner.vim), waits for the
" render, and term_dumpwrite()s the screen. Each dump is compared to a committed
" golden; NEODIFF_UPDATE=1 regenerates the goldens instead.
"
" Because it drives real terminals, the outer Vim must run under a pty -- ci/run.sh
" wraps it with `script`. Goldens are only valid against the pinned editor
" versions in ci/Dockerfile. Exits non-zero (via :cquit) on any mismatch.
" ==============================================================================

if !has('terminal') || !exists('*term_dumpwrite')
    echoerr 'screendump.vim requires Vim built with +terminal'
    cquit 1
endif

let s:dir = expand('<sfile>:p:h')
let s:dumps = s:dir . '/dumps'
if !isdirectory(s:dumps)
    call mkdir(s:dumps, 'p')
endif
let s:inner = s:dir . '/screendump_inner.vim'
let s:update = $NEODIFF_UPDATE !=# ''
let s:rows = 30
let s:cols = 120
let g:sd_failures = []

" Editors to capture: [dump name, binary]. Each renders to its own golden, since
" vim and nvim paint the diff differently (nvim has the extra pane tinting).
let s:editors = [['vim', 'vim'], ['nvim', 'nvim']]

" Launch a:editor_bin in a terminal running the fixture view, wait until the
" sidebar header and the modified-file diff have rendered, and return the buffer.
function! s:Render(editor_bin) abort
    let l:cmd = [a:editor_bin, '-Nu', 'ci/vimrc', '--cmd', 'set tabpagemax=50',
        \ '-c', 'source ' . s:inner]
    let l:buf = term_start(l:cmd, {
        \ 'term_rows': s:rows, 'term_cols': s:cols,
        \ 'term_kill': 'kill', 'norestore': 1})

    " Poll until both the sidebar header and the modified-file diff content are
    " on screen, so the dump captures a fully rendered view rather than a partial
    " one. Give up after a generous deadline.
    let l:tries = 200
    while l:tries > 0
        call term_wait(l:buf, 50)
        let l:screen = join(map(range(1, s:rows), 'term_getline(l:buf, v:val)'), "\n")
        if l:screen =~# 'neodiff' && l:screen =~# 'changed'
            break
        endif
        let l:tries -= 1
    endwhile
    " Final settle so late paints (fold text, pane tint) land before the dump.
    call term_wait(l:buf, 500)
    return l:buf
endfunction

for [s:name, s:bin] in s:editors
    let s:buf = s:Render(s:bin)
    let s:actual = s:dumps . '/view.' . s:name . '.dump'
    let s:golden = s:dumps . '/view.' . s:name . '.golden'
    call term_dumpwrite(s:buf, s:actual)
    call job_stop(term_getjob(s:buf), 'kill')
    call term_wait(s:buf, 100)
    execute 'bwipe! ' . s:buf

    if s:update
        call writefile(readfile(s:actual), s:golden)
        echo 'updated ' . s:golden
    elseif !filereadable(s:golden)
        call add(g:sd_failures,
            \ s:name . ': no golden yet (' . s:golden . '); run with NEODIFF_UPDATE=1')
    elseif readfile(s:actual) !=# readfile(s:golden)
        call add(g:sd_failures,
            \ s:name . ': screen differs from golden -- compare with '
            \ . ':call term_dumpdiff(' . string(s:actual) . ', ' . string(s:golden) . ')')
    endif
endfor

call writefile(g:sd_failures, s:dumps . '/last_result.txt')
if empty(g:sd_failures)
    echo 'screendump: PASS (' . len(s:editors) . ' editors)'
    qall!
else
    for s:msg in g:sd_failures
        echo 'screendump FAIL: ' . s:msg
    endfor
    cquit 1
endif
