# Functional description

Command line utility which wraps Run Execute Print Loop (REPL) in the way that it can be communicated by sending commands
and receiving responses through some channel (e.g. UNIX socket).

It is important that backend REPL process was persistent. i.e. different client requests just changes server state, but
doesn't re-create the instacne

usual flow is the following:
client sends message, server executes it in REPL and returns output as a reply. (client usually ends it's live at this
point)

server should communicate with clients through unix socket

server's own stain and stdout should implement several admin command:
 - close/quit - stop the server;
 - tail - show latest messages;
 - stats - show input/output messages statistics.

Special functions:
- repl post - doesn't wait any response/output from backend
- repl editor-send - special version, with input preprocessing and output crafting.
  It also implies command echoing in the output. (the idea is to bein able feed the command to
  the tool, and replace it with newly crafted output from repl if command implies it)

  - if input includes markdown code section begin, it should be cut-off before feeding to repl
  "```bash\nrepl_cmd" should result in "repl_cmd" for the backend programm
  "repl_cmd\n```" should result in "repl_cmd" for the backend programm

  - if input contains special lines "#=>\n" and/or "#==\n" text between shold be removed,
    and repl output of the command should be placed here. 
    NB! if '#==' line is ommited, first line without comment is considered end of output block

  - if there are multiple '#=>' it means command should be splitted before feeding to repl backend

  - if there are no '#=>' lines only last command output

  - each output line is prepended by '# 'c haracter
   

# Usage examples

```sh
# server
$ repl kernel irb
Starting kernel 'irb' on socket '/tmp/repl-kernel-ZDAECVE'
> 

```

```sh
# client
$ echo "a=[1,2,3]" | repl send
=> [1, 2, 3]

$ echo 'a[1]' | repl send
=> 3
```

```sh
# editor client
$ echo '
ls
#=>
# README.md  repl  test
#==
ls
#=>
# README.md  repl  test  z.txt
#==
' | repl editor-send
```



# Implementation

Single Ruby file (`repl`, stdlib only, no gems) plus `test/repl_test.rb`
(minitest). Install by copying `repl` anywhere on `$PATH`.

```sh
ruby test/repl_test.rb      # run all tests
```

The kernel runs as a child process attached to plain pipes (not a PTY), so
REPLs disable their line editors and produce clean, escape-free output. Output
is returned exactly as the REPL prints it, minus the echoed input, the prompt
and internal markers.

## Commands

```
repl kernel [options] COMMAND [ARGS...]   start a server
repl send [options] [TEXT...]             send a command (stdin if no TEXT)
repl post [options] [TEXT...]             send a command, expect no answer
repl editor-send [options] [TEXT...]      send an editor region, craft its output
repl signal [options] [NAME]              signal the kernel (default INT)
repl list                                 list running servers
repl version | help
```

`send`, `post` and `editor-send` take the same `--socket` option and read
stdin when no TEXT is given.

## post

`repl post` writes the command to the kernel and returns at once, without
waiting for (or reading) an answer; the output is dropped by the next
command. It never takes the kernel lock, so it can also answer a command that
is currently reading stdin.

```sh
$ echo 'gets.chomp' | repl send &   # kernel waits for input
$ echo 'hello' | repl post          # feed it
```

## editor-send

`repl editor-send` is meant to be bound to an editor key: feed it the selected
region, replace the region with what it prints. The region is echoed back with
every output block filled in with a fresh answer.

* a markdown fence around the region (` ```bash `, ` ``` `) is kept in the
  output but cut off before the code reaches the kernel;
* `#=>` opens an output block, `#==` closes it; the old contents are dropped
  and replaced. Without a closing `#==` the block ends at the first line that
  is not a comment;
* every `#=>` splits the region: the code above it is one command;
* without any `#=>` the whole region is a single command and its output is
  appended at the end;
* answer lines are prefixed with `# `, so the result stays valid source.

```sh
$ printf 'a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n' | repl editor-send
a = [1,2,3]
#=>
# [1, 2, 3]
#==
a[1]
#=>
# 2
#==
```

`kernel` options:

| option | meaning |
| --- | --- |
| `--socket PATH` | socket to listen on (default `/tmp/repl-kernel-XXXXXXX`) |
| `--marker TEMPLATE` | printf template making the kernel echo a token, e.g. `--marker 'puts "%s"'` |
| `--prompt REGEX` | regex matching the kernel prompt |
| `--idle SECONDS` | silence marking the end of an answer (default 0.3) |
| `--wait SECONDS` | wait for the first byte of an answer (default 2.0) |
| `--timeout SECONDS` | inactivity limit in marker/prompt mode (default 30) |
| `--history N` | messages kept for `tail` (default 100) |

## Knowing when an answer is complete

Three strategies, in order of reliability:

1. `--marker` — a token is printed after every command; exact, and safe for
   long running commands. Recommended: `repl kernel --marker 'puts "%s"' irb`.
2. `--prompt` — read until the kernel prints its prompt again, e.g.
   `repl kernel --prompt '>>> ' python3 -i -u`.
3. neither — read until the kernel is silent for `--idle` seconds. Works with
   any REPL but can cut long computations short. `--wait` must be longer than
   the kernel's start-up time.

## Interrupting a blocking command

The kernel runs in its own process group, so signals can be delivered while a
command is still running (the server never takes the kernel lock to signal it):

```sh
$ echo 'sleep 300' | repl send      # blocks
$ repl signal ^C                    # from another shell
sent SIGINT to pid 2000658
```

Signals are given as names (`INT`, `TSTP`, `CONT`, `TERM`, ...) or as control
characters (`^C`, `^Z`, `^\`, `ctrl-c`). `^D` is special: it closes the
kernel's input, i.e. sends EOF. The same is available in the admin console as
`signal`, `interrupt` and `eof`.

The signals a terminal generates from a keystroke (`INT`, `QUIT`, `TSTP`) are
delivered like a terminal delivers them: to the kernel's foreground job, i.e.
to the processes the kernel has spawned, and only to the kernel itself when it
has none. This matters for shell kernels -- `repl kernel bash` running
`sleep 50` interrupts the `sleep`, whereas a SIGINT for `bash` itself would
end the session. Other signals always go to the whole process group.

## Finding the server

`repl send` resolves the socket in this order:

1. `--socket PATH`
2. `$REPL_SOCKET`
3. the only running server, taken from the registry (`~/.repl/servers.json`,
   overridable with `$REPL_HOME`)

With several servers running, `repl send` lists them and asks for `--socket`.

## Admin console

The server reads admin commands from its own stdin:

```
> tail 5          # show latest messages
> stats           # socket, kernel, uptime, request and byte counters
> post puts 1     # send a command without waiting for its output
> attach 6 * 7    # run one command on the kernel
> attach          # enter attached mode: talk to the kernel directly
irb> x = 100
100
irb> detach
> signal ^C       # interrupt the kernel; `interrupt` and `eof` also work
> close           # or quit -- stop the server
> help
```

Commands entered in attached mode go through the same path as client requests,
so they show up in `stats` and `tail`.

In attached mode `Ctrl-C` behaves like a terminal interrupt: it is forwarded to
the kernel (`SIGINT`) instead of stopping the server, so a runaway command can
be aborted without losing the session. Outside attached mode `Ctrl-C` still
stops the server.

Stopping the server (admin command, `Ctrl-D`, `SIGINT` or `SIGTERM`) shuts the
kernel down, removes the socket and unregisters the server.

# TODO

- Intrdocude 'restart' admin command
- Fix 'tail' as though it can continiously show updates
