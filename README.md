# Functional description


Command line utility which wraps Run Execute Print Loop (REPL) in the way that it can be communicated by sending commands
and receiving responses through some channel (e.g. UNIX socket).

It is important that backend REPL process was persistent. i.e. different client requests just changes server state, but
doesn't re-create the instacne

usual flow is the following:
client sends message, server executes it in REPL and returns output as a reply. (client usually ends it's live at this
point)

server should communicate with clients through unix socket

## Special functions: notebook


- repl notebook - special send version, with input preprocessing and output crafting.
  It also implies command echoing in the output. (the idea is to bein able feed the command to
  the tool, and replace it with newly crafted output from repl if command implies it)

- if input includes markdown code section begin, it should be cut-off (with any preceeding lines
  before feeding to repl "```bash\nrepl_cmd" should result in "repl_cmd" for the backend programm
  "repl_cmd\n```" should result in "repl_cmd" for the backend programm

- if input contains special lines "#=>\n" and/or "#==\n" text between shold be removed,
  and repl output of the command should be placed here. 
  NB! if '#==' line is ommited, first line without comment is considered end of output block

- the terminator of a freshly answered block carries the id of the answer,
  '#==[45]'; `repl show 45` hands out the whole of that answer again

- if there are multiple '#=>' it means command should be splitted before feeding to repl backend

- if there are no '#=>' lines the whole buffer is one block

- each block shows the output of all its commands, joined in one block of text

- each output line is prepended by '# 'c haracter



# Usage examples

```sh
# server
$ repl kernel bash
bash-5.3$ 
```

```sh
# client
$ echo "a=[1,2,3]" | repl send
=> [1, 2, 3]

$ echo 'a[1]' | repl send
=> 2
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
' | repl notebook
```

```sh
$ echo '' |./repl post
# $? == 0
```

```sh
$ echo '(sleep 5 && echo "done")'| timeout 1 ./repl post
# $? == 0

./repl stop
# $? == 0
```

```bash
$ echo 'sleep 5' | timeout 1 ./repl send
# $? != 0
```

```bash
$ echo Ok |timeout 1 ./repl send
Ok
# $? == 0
```

```bash
$ printf 'a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n' | repl notebook
a = [1,2,3]
#=>
# [1, 2, 3]
#==[3]
a[1]
#=>
# 2
#==[4]
```

```sh
# the whole answer a block shows an excerpt of
$ repl show 4
2
```

# Vim plugin and specific edior commands


# TODO
- convert usage examples to unit tests
- consider changing client-server protocol to json

# tw=80
