" autoload/repl.vim -- talk to a `repl` kernel from the buffer.
"
" Two ways of sending a region:
"   * filter -- the region is replaced by `repl notebook`, which echoes the
"     code back with every '#=>' output block filled in with a fresh answer;
"   * post   -- the region is written to `repl post`, nothing comes back and
"     the buffer is left alone.

let s:fence = '^\s*```'
let s:blank = '^\s*$'
" <plugin>/autoload/repl.vim -> <plugin> -> the repo holding the `repl` script.
let s:bundled = expand('<sfile>:p:h:h:h') . '/repl'

" The `repl` script: g:repl_command, then ./repl, then the copy shipped next
" to this plugin, then whatever is on $PATH.
function! repl#executable() abort
  if !empty(get(g:, 'repl_command', ''))
    return g:repl_command
  endif
  if executable('/Volumes/Machintosh/Users/igk/src/repl_v2/repl')
    return './repl'
  endif
  let l:bundled = s:bundled
  if executable(l:bundled)
    return l:bundled
  endif
  return 'repl'
endfunction

function! s:command(subcommand) abort
  let l:parts = [repl#executable(), a:subcommand]
  let l:socket = get(b:, 'repl_socket', get(g:, 'repl_socket', ''))
  if !empty(l:socket)
    let l:parts += ['--socket', shellescape(l:socket)]
  endif
  return join(l:parts, ' ')
endfunction

function! s:error(message) abort
  echohl ErrorMsg
  echomsg 'repl: ' . a:message
  echohl None
endfunction

" Run the command with the lines on its standard input. Returns the output, or
" v:null when the command failed (its message is reported).
function! s:run(command, lines) abort
  let l:out = system(a:command, join(a:lines, "\n") . "\n")
  if v:shell_error != 0
    call s:error(substitute(l:out, '\n\+$', '', ''))
    return v:null
  endif
  return l:out
endfunction

" --- regions ----------------------------------------------------------------

" The paragraph under the cursor: the run of non-blank lines around it.
function! repl#paragraph() abort
  if getline('.') =~# s:blank
    return []
  endif
  let l:first = line('.')
  while l:first > 1 && getline(l:first - 1) !~# s:blank
    let l:first -= 1
  endwhile
  let l:last = line('.')
  while l:last < line('$') && getline(l:last + 1) !~# s:blank
    let l:last += 1
  endwhile
  return [l:first, l:last]
endfunction

" The markdown code block under the cursor, fences included. `notebook`
" keeps the fences in its answer but hides them from the kernel.
function! repl#section() abort
  let l:cursor = line('.')
  let l:start = 0
  for l:lnum in range(1, line('$'))
    if getline(l:lnum) !~# s:fence
      continue
    endif
    if l:start == 0
      let l:start = l:lnum
    else
      if l:cursor >= l:start && l:cursor <= l:lnum
        return [l:start, l:lnum]
      endif
      let l:start = 0
    endif
  endfor
  " An unterminated block still counts, up to the end of the buffer.
  if l:start != 0 && l:cursor >= l:start
    return [l:start, line('$')]
  endif
  return []
endfunction

" --- actions ----------------------------------------------------------------

" Replace lines [first, last] with the answer of `repl notebook`.
function! repl#send(first, last) abort
  let l:out = s:run(s:command('notebook'), getline(a:first, a:last))
  if l:out is v:null
    return
  endif
  let l:lines = split(l:out, "\n", 1)
  if !empty(l:lines) && l:lines[-1] ==# ''
    call remove(l:lines, -1)
  endif
  if empty(l:lines)
    return
  endif
  let l:view = winsaveview()
  call setline(a:first, l:lines[0])
  if a:last > a:first
    call deletebufline('%', a:first + 1, a:last)
  endif
  if len(l:lines) > 1
    call append(a:first, l:lines[1:])
  endif
  call winrestview(l:view)
endfunction

" Write lines [first, last] to `repl post`; the buffer is not touched. Fences
" are dropped first: `post` sends its input to the kernel as it is, and a
" '```bash' line is three backticks to a shell - an unbalanced pair that opens
" a command substitution, swallows the block and leaves a nested shell holding
" the kernel, after which nothing answers any more.
function! repl#post(first, last) abort
  let l:lines = filter(getline(a:first, a:last), 'v:val !~# s:fence')
  if empty(filter(copy(l:lines), 'v:val !~# ''^\s*$'''))
    call s:error('nothing to post')
    return
  endif
  if s:run(s:command('post'), l:lines) is v:null
    return
  endif
  echo printf('repl: posted %d line%s', len(l:lines), len(l:lines) == 1 ? '' : 's')
endfunction

" --- clearing ---------------------------------------------------------------

let s:open = '^\s*#=>\s*$'
" The terminator carries the id of the answer it closes: '#==' or '#==[45]'.
let s:close = '^#==\%(\[[0-9]\+\]\)\?$'

" First line after the output block opened on the line before `start`, i.e. the
" block is [start, result - 1]. The rules are the ones `repl notebook` uses
" when it drops a stale block: comment lines up to a '#==' terminator, or up to
" the first line that is not a comment; blank lines belong to the block only
" when a '#==' still follows.
function! s:block_end(start, limit) abort
  let l:lnum = a:start
  while l:lnum <= a:limit
    let l:line = trim(getline(l:lnum))
    if l:line =~# s:close
      return l:lnum + 1
    endif
    if empty(l:line)
      let l:next = l:lnum
      while l:next <= a:limit && empty(trim(getline(l:next)))
        let l:next += 1
      endwhile
      if l:next <= a:limit && trim(getline(l:next)) =~# s:close
        return l:next + 1
      endif
      return l:lnum
    endif
    if l:line[0] !=# '#'
      return l:lnum
    endif
    let l:lnum += 1
  endwhile
  return l:lnum
endfunction

" Empty every output block in [first, last], keeping its '#=>' opener.
function! repl#clear(first, last) abort
  let l:view = winsaveview()
  let l:last = a:last
  let l:lnum = a:first
  let l:cleared = 0
  while l:lnum <= l:last
    if getline(l:lnum) =~# s:open
      " The block belongs to the '#=>' just found, so it is emptied whole even
      " when the region cuts it in half.
      let l:end = s:block_end(l:lnum + 1, line('$'))
      if l:end > l:lnum + 1
        call deletebufline('%', l:lnum + 1, l:end - 1)
        let l:last = max([l:lnum, l:last - (l:end - l:lnum - 1)])
        let l:cleared += 1
      endif
    endif
    let l:lnum += 1
  endwhile
  call winrestview(l:view)
  echo l:cleared == 0 ? 'repl: no output block to clear'
        \ : printf('repl: cleared %d block%s', l:cleared, l:cleared == 1 ? '' : 's')
endfunction

function! repl#clear_paragraph() abort
  call s:region('clear', 'paragraph')
endfunction

function! repl#clear_section() abort
  call s:region('clear', 'section')
endfunction

function! repl#clear_operator(type) abort
  call repl#clear(line("'["), line("']"))
endfunction

function! s:region(kind, what) abort
  let l:range = a:what ==# 'paragraph' ? repl#paragraph() : repl#section()
  if empty(l:range)
    call s:error(a:what ==# 'paragraph' ? 'no paragraph under the cursor'
          \ : 'no ``` block under the cursor')
    return
  endif
  call call('repl#' . a:kind, l:range)
endfunction

function! repl#send_paragraph() abort
  call s:region('send', 'paragraph')
endfunction

function! repl#send_section() abort
  call s:region('send', 'section')
endfunction

function! repl#post_paragraph() abort
  call s:region('post', 'paragraph')
endfunction

function! repl#post_section() abort
  call s:region('post', 'section')
endfunction

" --- operators (g@) ---------------------------------------------------------

function! repl#send_operator(type) abort
  call repl#send(line("'["), line("']"))
endfunction

function! repl#post_operator(type) abort
  call repl#post(line("'["), line("']"))
endfunction
