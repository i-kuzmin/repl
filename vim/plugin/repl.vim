" plugin/repl.vim -- commands and key bindings for the `repl` kernel.
"
" Filtering (the region is replaced by the crafted answer):
"   <Leader>rr   paragraph          <Leader>rR   ``` block
"   <Leader>rm{motion}              <Leader>rr / <Leader>rR on a selection
" Posting (nothing is written back):
"   <Leader>Rr   paragraph          <Leader>RR   ``` block
"   <Leader>Rm{motion}              <Leader>Rr / <Leader>RR on a selection
" Clearing (the output blocks are emptied, only '#=>' is kept):
"   <Leader>rc   paragraph          <Leader>rC   ``` block
"   <Leader>rM{motion}              <Leader>rc / <Leader>rC on a selection
"
" The lower case key takes the paragraph, the upper case one the ``` block; in
" Visual mode both take the selection. No default binding is a prefix of
" another one, so nothing has to wait for 'timeout'.
" Set g:repl_no_mappings to keep the <Plug> mappings only, g:repl_command to
" pick the script and g:repl_socket (or b:repl_socket) to pick the kernel.

if exists('g:loaded_repl')
  finish
endif
let g:loaded_repl = 1

let s:save_cpo = &cpoptions
set cpoptions&vim

command! -range ReplSend call repl#send(<line1>, <line2>)
command! -range ReplPost call repl#post(<line1>, <line2>)
command! -range=% ReplClear call repl#clear(<line1>, <line2>)
command! ReplSendParagraph call repl#send_paragraph()
command! ReplSendSection call repl#send_section()
command! ReplPostParagraph call repl#post_paragraph()
command! ReplPostSection call repl#post_section()
command! ReplParagraphClear call repl#clear_paragraph()
command! ReplSectionClear call repl#clear_section()

nnoremap <silent> <Plug>(repl-send-paragraph) :<C-u>call repl#send_paragraph()<CR>
nnoremap <silent> <Plug>(repl-send-section) :<C-u>call repl#send_section()<CR>
xnoremap <silent> <Plug>(repl-send) :<C-u>call repl#send(line("'<"), line("'>"))<CR>
nnoremap <silent> <Plug>(repl-send-operator) :<C-u>set operatorfunc=repl#send_operator<CR>g@

nnoremap <silent> <Plug>(repl-post-paragraph) :<C-u>call repl#post_paragraph()<CR>
nnoremap <silent> <Plug>(repl-post-section) :<C-u>call repl#post_section()<CR>
xnoremap <silent> <Plug>(repl-post) :<C-u>call repl#post(line("'<"), line("'>"))<CR>
nnoremap <silent> <Plug>(repl-post-operator) :<C-u>set operatorfunc=repl#post_operator<CR>g@

nnoremap <silent> <Plug>(repl-clear-paragraph) :<C-u>call repl#clear_paragraph()<CR>
nnoremap <silent> <Plug>(repl-clear-section) :<C-u>call repl#clear_section()<CR>
xnoremap <silent> <Plug>(repl-clear) :<C-u>call repl#clear(line("'<"), line("'>"))<CR>
nnoremap <silent> <Plug>(repl-clear-operator) :<C-u>set operatorfunc=repl#clear_operator<CR>g@

" Bind every key of `lhss` that is still free, unless the user already mapped
" something to `plug` himself.
function! s:map(mode, lhss, plug) abort
  if hasmapto(a:plug, a:mode)
    return
  endif
  for l:lhs in a:lhss
    if empty(maparg(l:lhs, a:mode))
      execute a:mode . 'map <silent> ' . l:lhs . ' ' . a:plug
    endif
  endfor
endfunction

if !get(g:, 'repl_no_mappings', 0)
  call s:map('n', ['<Leader>rr'], '<Plug>(repl-send-paragraph)')
  call s:map('n', ['<Leader>rR'], '<Plug>(repl-send-section)')
  call s:map('n', ['<Leader>rm'], '<Plug>(repl-send-operator)')
  call s:map('x', ['<Leader>rr', '<Leader>rR'], '<Plug>(repl-send)')

  call s:map('n', ['<Leader>Rr'], '<Plug>(repl-post-paragraph)')
  call s:map('n', ['<Leader>RR'], '<Plug>(repl-post-section)')
  call s:map('n', ['<Leader>Rm'], '<Plug>(repl-post-operator)')
  call s:map('x', ['<Leader>Rr', '<Leader>RR'], '<Plug>(repl-post)')

  call s:map('n', ['<Leader>rc'], '<Plug>(repl-clear-paragraph)')
  call s:map('n', ['<Leader>rC'], '<Plug>(repl-clear-section)')
  call s:map('n', ['<Leader>rM'], '<Plug>(repl-clear-operator)')
  call s:map('x', ['<Leader>rc', '<Leader>rC'], '<Plug>(repl-clear)')
endif

let &cpoptions = s:save_cpo
unlet s:save_cpo
