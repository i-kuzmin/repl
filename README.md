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
repl list                                 list running servers
repl version | help
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
   any REPL but can cut long computations short.

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
> tail 5     # show latest messages
> stats      # socket, kernel, uptime, request and byte counters
> close      # or quit -- stop the server
> help
```

Stopping the server (admin command, `Ctrl-D`, `SIGINT` or `SIGTERM`) shuts the
kernel down, removes the socket and unregisters the server.
