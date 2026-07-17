" ==============================================================================
" Symbol-search checks. neodiff#CollectSymbols() shells out to ctags, so this
" runs only in the CI container (where Universal Ctags is installed). It builds a
" view over C files with known symbols (empty setups, no fugitive needed) and
" asserts the collected symbols, their owning entry ids, and line numbers.
"
"   nvim -Nu ci/vimrc --headless -S ci/test_symbols.vim
"
" Exits 0 on success, 1 (via :cquit) on any failure. The interactive picker
" (fzf / inputlist) and the jump are verified by hand.
" ==============================================================================

source <sfile>:p:h/fixtures.vim

let g:failures = []
function! Assert(cond, msg) abort
    if !a:cond
        call add(g:failures, a:msg)
    endif
endfunction

" Two C files with distinct, known symbols; alpha.c lives in a subdirectory so
" the entry labels differ from the file tails.
let s:file_a = NdFile('pkg/alpha.c',
    \ ['int alpha(void) { return 1; }', '', 'void beta(int count) { }'])
let s:file_b = NdFile('gamma.c',
    \ ['struct Point { int x; };', 'int gamma_fn(void) { return 0; }'])
let s:entries = [
    \ NdEntry('pkg/alpha.c', s:file_a, '', '', 'M', 0),
    \ NdEntry('gamma.c', s:file_b, '', '', 'A', 0)]

" Open one tab per entry, then hand them to the plugin (as the shell would).
let s:idx = 0
for s:entry in s:entries
    if s:idx == 0
        execute 'edit ' . fnameescape(s:entry.file)
    else
        execute 'tabnew ' . fnameescape(s:entry.file)
    endif
    let s:idx += 1
endfor
call neodiff#Setup('Symbols', s:entries, [])

let s:symbols = neodiff#CollectSymbols()
let s:names = map(copy(s:symbols), 'v:val.name')
call Assert(index(s:names, 'alpha') >= 0, 'collect: found alpha')
call Assert(index(s:names, 'beta') >= 0, 'collect: found beta')
call Assert(index(s:names, 'gamma_fn') >= 0, 'collect: found gamma_fn')

" Each symbol is attributed to the right entry id, with a working-file line.
for s:symbol in s:symbols
    if s:symbol.name ==# 'alpha'
        call Assert(s:symbol.id == 0 && s:symbol.line == 1, 'collect: alpha id/line')
    elseif s:symbol.name ==# 'gamma_fn'
        call Assert(s:symbol.id == 1 && s:symbol.line == 2, 'collect: gamma_fn id/line')
    endif
endfor

" fzf picker wiring. Stub fzf#run/fzf#wrap on the runtimepath (autoload functions
" must live in a file named fzf.vim) so the fzf branch runs headlessly. The
" fzf#wrap stub mimics the real one, which appends its --expect keys to 'options'
" by string concatenation -- so it throws if neodiff passes a List (the bug being
" guarded against). Then drive the captured sink and confirm the jump.
let g:nd_fzf_spec = {}
let s:fzf_stub = tempname()
call mkdir(s:fzf_stub . '/autoload', 'p')
call writefile([
    \ 'function! fzf#wrap(spec) abort',
    \ '    let l:spec = copy(a:spec)',
    \ '    let l:spec.options = get(l:spec, "options", "") . " --expect=ctrl-t"',
    \ '    return l:spec',
    \ 'endfunction',
    \ 'function! fzf#run(spec) abort',
    \ '    let g:nd_fzf_spec = a:spec',
    \ 'endfunction'], s:fzf_stub . '/autoload/fzf.vim')
execute 'set runtimepath^=' . fnameescape(s:fzf_stub)
" Do NOT source it here: SearchSymbols must detect fzf from the autoload file on
" the runtimepath (exists('*fzf#run') stays false until the first call), and then
" trigger the autoload by calling fzf#run. This guards the detection bug where
" exists('*fzf#run') alone left fzf unused until something else loaded it.
call Assert(!exists('*fzf#run'), 'fzf: autoload not yet sourced (detection must not need exists)')

let s:fzf_ok = 1
try
    execute "normal \<C-p>"
catch
    let s:fzf_ok = 0
    call add(g:failures, 'fzf: picker threw (options must be a String): ' . v:exception)
endtry
call Assert(type(get(g:nd_fzf_spec, 'options', 0)) == type(''), 'fzf: options is a String')
call Assert(type(get(g:nd_fzf_spec, 'source', 0)) == type([]), 'fzf: source is a List')

if s:fzf_ok && has_key(g:nd_fzf_spec, 'sink')
    let s:gamma_line = ''
    for s:line in g:nd_fzf_spec.source
        if s:line =~# 'gamma_fn'
            let s:gamma_line = s:line
            break
        endif
    endfor
    call Assert(s:gamma_line !=# '', 'fzf: source has a readable gamma_fn entry')
    if s:gamma_line !=# ''
        call g:nd_fzf_spec.sink(s:gamma_line)
        call Assert(gettabvar(tabpagenr(), 'neodiff_id', -9) == 1 && line('.') == 2,
            \ 'fzf: selecting gamma_fn jumps to gamma.c:2')
    endif
endif

if empty(g:failures)
    echo 'symbols: PASS (' . len(s:symbols) . ' symbols)'
    qall!
else
    for s:msg in g:failures
        echo 'symbols FAIL: ' . s:msg
    endfor
    cquit 1
endif
