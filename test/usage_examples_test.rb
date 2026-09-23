# frozen_string_literal: true
#
# Exercises the CLI exactly as documented in the "Usage examples" section of
# README.md: a `repl kernel bash` server started in the background, driven
# through the real `repl` executable (not the library API) via `send`,
# `post`, `notebook` and `stop`, asserting the same output/exit codes shown
# in the docs.
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tempfile'

REPL_BIN = File.expand_path('../repl', __dir__)

describe 'README usage examples' do
  before do
    @server_in, @server_in_w = IO.pipe
    @server_out_r, @server_out_w = IO.pipe
    @server_pid = Process.spawn(
      REPL_BIN, 'kernel', 'bash', '--norc', '--noprofile', '-i',
      in: @server_in, out: @server_out_w, err: @server_out_w
    )
    @server_in_w.close
    @server_out_w.close
    @socket = "/tmp/REPL.#{@server_pid}.sock"

    Timeout.timeout(5) { sleep 0.05 until File.exist?(@socket) }
  end

  after do
    Process.kill('TERM', @server_pid)
    Process.wait(@server_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    [@server_in, @server_in_w, @server_out_r, @server_out_w].each do |io|
      io.close unless io.closed?
    end
    File.unlink(@socket) if File.exist?(@socket)
  end

  def repl(*args, stdin_data: '')
    Open3.capture3(REPL_BIN, *args, '--socket', @socket, stdin_data: stdin_data)
  end

  # The id a terminator carries is the number of the request that answered the
  # block, which depends on how many requests the server has served already.
  def ids_off(out)
    out.gsub(/^(\s*#==)\[[0-9]+\]$/, '\1')
  end

  it 'runs a bash kernel and evaluates a variable assignment then expansion' do
    out, _err, status = repl('send', stdin_data: "A=10\nB=20\nprintf \"$A $B end\"\n")
    _(status.success?).must_equal true
    _(out).must_equal "10 20 end\n"
  end

  it 'post: sends a command and expects no answer ($? == 0)' do
    _out, _err, status = repl('post', stdin_data: '')
    _(status.success?).must_equal true
  end

  it 'post: returns immediately even for a slow command ($? == 0)' do
    out, _err, status = Open3.capture3(
      'timeout', '1', REPL_BIN, 'post', '--socket', @socket,
      stdin_data: "(sleep 5 && echo \"done\")\n"
    )
    _(status.success?).must_equal true
    _(out).must_equal ''
  end

  it 'send: times out on a slow command ($? != 0)' do
    _out, _err, status = Open3.capture3(
      'timeout', '1', REPL_BIN, 'send', '--socket', @socket,
      stdin_data: "sleep 5\n"
    )
    _(status.success?).must_equal false
  end

  it 'send: returns the command output within the timeout' do
    out, _err, status = Open3.capture3(
      'timeout', '1', REPL_BIN, 'send', '--socket', @socket,
      stdin_data: "echo Ok\n"
    )
    _(status.success?).must_equal true
    _(out).must_equal "Ok\n"
  end

  it 'notebook: echoes the buffer with every output block filled in' do
    out, _err, status = repl(
      'notebook',
      stdin_data: "echo one\n#=>\n# stale\n#==\necho two\n#=>\n#==\n"
    )
    _(status.success?).must_equal true
    _(ids_off(out))
      .must_equal "echo one\n#=>\n# one\n#==\necho two\n#=>\n# two\n#==\n"
  end

  it 'notebook: hides the fences from the kernel and echoes them back' do
    out, _err, status = repl(
      'notebook', stdin_data: "```sh\necho one\n#=>\n#==\n```\n"
    )
    _(status.success?).must_equal true
    _(ids_off(out)).must_equal "```sh\necho one\n#=>\n# one\n#==\n```\n"
  end

  it 'notebook: appends one block when the buffer has no marker' do
    out, _err, status = repl('notebook', stdin_data: "A=1\necho $A\n")
    _(status.success?).must_equal true
    _(ids_off(out)).must_equal "A=1\necho $A\n#=>\n# 1\n#==\n"
  end

  it 'notebook: joins the answers of every command of a block' do
    out, _err, status = repl(
      'notebook', stdin_data: "echo one\necho two\necho three\n#=>\n#==\n"
    )
    _(status.success?).must_equal true
    _(ids_off(out)).must_equal \
      "echo one\necho two\necho three\n#=>\n# one\n# two\n# three\n#==\n"
  end

  it 'notebook: stamps the id of the answer into the terminator' do
    out, _err, status = repl('notebook', stdin_data: "echo one\n#=>\n#==\n")
    _(status.success?).must_equal true
    _(out).must_match(/\Aecho one\n\#=>\n\# one\n\#==\[[0-9]+\]\n\z/)
  end

  it 'show: hands out the answer the terminator points at' do
    out, _err, status = repl('notebook', stdin_data: "echo one\n#=>\n#==\n")
    _(status.success?).must_equal true
    id = out[/\#==\[([0-9]+)\]/, 1]
    _(id).wont_be_nil

    shown, _err, status = Open3.capture3(
      REPL_BIN, 'show', '--socket', @socket, id, stdin_data: ''
    )
    _(status.success?).must_equal true
    _(shown).must_equal "one\n"
  end

  it 'show: fails on an id nothing was stored under' do
    _out, _err, status = Open3.capture3(
      REPL_BIN, 'show', '--socket', @socket, '999999', stdin_data: ''
    )
    _(status.success?).must_equal false
  end

  it 'send: keeps every answer of a multi command request' do
    out, _err, status = repl('send', stdin_data: "echo one\necho two\n")
    _(status.success?).must_equal true
    _(out).must_equal "one\ntwo\n"
  end

  it 'stop: stops the kernel ($? == 0)' do    _out, _err, status = repl('stop')
    _(status.success?).must_equal true
    Process.wait(@server_pid)
    _(File.exist?(@socket)).must_equal false
  end

  # `set` takes its key=value as a trailing positional argument, so --socket
  # has to come before it (OptionParser stops parsing at the first
  # non-option argument), unlike the other subcommands which take no
  # positional arguments of their own.
  def set(value)
    Open3.capture3(REPL_BIN, 'set', '--socket', @socket, value, stdin_data: '')
  end

  it 'set output=PATH: redirects the kernel raw output to a file, and back to stdout' do
    Tempfile.create('repl-set-output') do |file|
      path = file.path

      _out, _err, status = set("output=#{path}")
      _(status.success?).must_equal true

      out, _err, status = repl('send', stdin_data: "echo redirected\n")
      _(status.success?).must_equal true
      _(out).must_equal "redirected\n"

      # The client's answer travels over the socket regardless of where the
      # kernel echoes its raw output, so the file is polled rather than
      # asserted on immediately.
      Timeout.timeout(2) { sleep 0.05 until File.read(path).include?('redirected') }

      _out, _err, status = set('output=stdout')
      _(status.success?).must_equal true

      size_before = File.size(path)
      out, _err, status = repl('send', stdin_data: "echo after\n")
      _(status.success?).must_equal true
      _(out).must_equal "after\n"
      sleep 0.2
      _(File.size(path)).must_equal size_before
    end
  end

  it 'set output=BADKEY: fails without touching the running kernel' do
    out, err, status = set('nonsense=1')
    _(status.success?).must_equal false
    _((out + err)).wont_be_empty

    out, _err, status = repl('send', stdin_data: "echo still-alive\n")
    _(status.success?).must_equal true
    _(out).must_equal "still-alive\n"
  end
end

describe 'kernel --output PATH' do
  before do
    @file = Tempfile.new('repl-kernel-output')
    @server_in, @server_in_w = IO.pipe
    @server_out_r, @server_out_w = IO.pipe
    @server_pid = Process.spawn(
      REPL_BIN, 'kernel', '--output', @file.path, 'bash', '--norc', '--noprofile', '-i',
      in: @server_in, out: @server_out_w, err: @server_out_w
    )
    @server_in_w.close
    @server_out_w.close
    @socket = "/tmp/REPL.#{@server_pid}.sock"

    Timeout.timeout(5) { sleep 0.05 until File.exist?(@socket) }
  end

  after do
    Process.kill('TERM', @server_pid)
    Process.wait(@server_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    [@server_in, @server_in_w, @server_out_r, @server_out_w].each do |io|
      io.close unless io.closed?
    end
    File.unlink(@socket) if File.exist?(@socket)
    @file.close
    @file.unlink
  end

  it 'echoes the kernel raw output to the given file from startup' do
    out, _err, status = Open3.capture3(
      REPL_BIN, 'send', '--socket', @socket, stdin_data: "echo direct\n"
    )
    _(status.success?).must_equal true
    _(out).must_equal "direct\n"

    Timeout.timeout(2) { sleep 0.05 until File.read(@file.path).include?('direct') }
    _(File.read(@file.path)).must_match(/direct/)
  end
end

describe 'client without a server' do
  # Log.raise used to call itself instead of ::Kernel.raise (REPL::Kernel
  # shadows the built-in), so this recursed and printed the same fatal line
  # until the stack ran out.
  it 'fails once with a message instead of recursing' do
    out, err, status = Open3.capture3(
      REPL_BIN, 'send', '--socket', '/tmp/REPL.0.sock', stdin_data: "echo hi\n"
    )
    _(status.success?).must_equal false
    _((out + err).lines.size).must_be :<=, 2
  end
end
