" ==============================================================================
" Fixture builders for the neodiff functional tests. These mirror the shell
" launcher's data model: NdEntry() produces the same {'label','file','setup',
" 'stat'[,'status','pinned']} dict that shell/neodiff.sh emits, and NdFile()
" backs an entry with a real on-disk buffer so tab open/close/reopen paths work.
"
" Entries here use an empty 'setup', so neodiff#Setup builds the tree, sidebar,
" title bar and tabs without needing fugitive or a real diff.
" ==============================================================================

" Per-run scratch directory holding the fixture buffer files.
let g:nd_tmpdir = tempname()
call mkdir(g:nd_tmpdir, 'p')

" Write a:lines under a:relpath inside the scratch dir and return the full path.
" Intermediate directories are created as needed.
function! NdFile(relpath, lines) abort
    let l:full = g:nd_tmpdir . '/' . a:relpath
    let l:dir = fnamemodify(l:full, ':h')
    if !isdirectory(l:dir)
        call mkdir(l:dir, 'p')
    endif
    call writefile(a:lines, l:full)
    return l:full
endfunction

" Build one entry dict. status is omitted when empty and pinned when zero, so the
" result matches _neodiff_entry's conditional fields.
function! NdEntry(label, file, setup, stat, status, pinned) abort
    let l:entry = {'label': a:label, 'file': a:file, 'setup': a:setup, 'stat': a:stat}
    if a:status !=# ''
        let l:entry.status = a:status
    endif
    if a:pinned
        let l:entry.pinned = 1
    endif
    return l:entry
endfunction

" Convenience: an entry backed by a one-line fixture file named after its label's
" tail, with an empty setup. label doubles as the repo-relative path.
function! NdDiffEntry(label, stat, status) abort
    let l:file = NdFile(a:label, ['fixture: ' . a:label])
    return NdEntry(a:label, l:file, '', a:stat, a:status, 0)
endfunction
