# frozen_string_literal: true
#
# Kernel metadata (name, cmd), output caching and the `get`/`ls` commands,
# driven through the real `repl` executable.
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'digest'

load File.expand_path('../repl', __dir__)

METADATA_BIN = File.expand_path('../repl', __dir__)

describe 'kernel metadata and caching' do
  def start_kernel(*options)
    @server_pid = Process.spawn(
      METADATA_BIN, 'kernel', '-c', '--output', File::NULL, *options,
      'bash', '--norc', '--noprofile', '-i',
      in: File::NULL, out: File::NULL, err: File::NULL
    )
    @socket = "/tmp/REPL.#{@server_pid}.sock"
    Timeout.timeout(5) { sleep 0.05 until File.exist?(@socket) }
  end

  after do
    Process.kill('TERM', @server_pid)
    Process.wait(@server_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    File.unlink(@socket) if File.exist?(@socket)
  end

  def repl(command, *args, stdin_data: '')
    Open3.capture3(METADATA_BIN, command, '--socket', @socket, *args,
                   stdin_data: stdin_data)
  end

  describe 'with defaults' do
    before { start_kernel }

    it 'get: prints every key when none is given' do
      out, _err, status = repl('get')
      _(status.success?).must_equal true
      _(out).must_equal "name=\ncmd=bash --norc --noprofile -i\ncaching=on\n" \
                        "output=#{File::NULL}\nloglevel=WARN\nlogfile=stdout\n"
    end

    it 'get: prints several keys in the requested order' do
      out, _err, status = repl('get', 'cmd', 'name')
      _(status.success?).must_equal true
      _(out).must_equal "cmd=bash --norc --noprofile -i\nname=\n"
    end

    it 'get: fails on an unknown key' do
      _out, _err, status = repl('get', 'name', 'bogus')
      _(status.success?).must_equal false
    end

    it 'set name: renames the kernel' do
      _out, _err, status = repl('set', 'name=other kernel')
      _(status.success?).must_equal true
      out, _err, _status = repl('get', 'name')
      _(out).must_equal "name=other kernel\n"
    end

    it 'get: reports loglevel and logfile changed by set' do
      repl('set', 'loglevel=INFO')
      repl('set', "logfile=#{File::NULL}")
      out, _err, _status = repl('get', 'loglevel', 'logfile')
      _(out).must_equal "loglevel=INFO\nlogfile=#{File::NULL}\n"
    end

    it 'set caching=off: keeps only the last answer' do
      _, _, status = repl('send', stdin_data: "echo one\n")
      _(status.success?).must_equal true
      _out, _err, status = repl('set', 'caching=off')
      _(status.success?).must_equal true
      _(repl('get', 'caching').first).must_equal "caching=off\n"
      _(repl('show').first).must_equal "one\n"

      repl('send', stdin_data: "echo two\n")
      _(repl('show').first).must_equal "two\n"
    end

    it 'get output: reports where the kernel output goes' do
      _(repl('get', 'output').first).must_equal "output=#{File::NULL}\n"
      repl('set', 'output=stdout')
      _(repl('get', 'output').first).must_equal "output=stdout\n"
    end

    it 'set key=: resets the key to its default' do
      repl('set', 'name=shell')
      repl('set', 'caching=off')
      repl('set', 'loglevel=INFO')
      repl('set', "logfile=#{File::NULL}")
      %w[name= caching= output= loglevel= logfile=].each do |reset|
        _(repl('set', reset)[2].success?).must_equal true
      end
      out, _err, _status = repl('get', 'name', 'caching', 'output', 'loglevel', 'logfile')
      _(out).must_equal "name=\ncaching=on\noutput=stdout\nloglevel=WARN\nlogfile=stdout\n"
    end

    it 'set caching: rejects a value that is not on/off' do
      _out, _err, status = repl('set', 'caching=maybe')
      _(status.success?).must_equal false
    end

    it 'ls: leaves the name field empty when no name is set' do
      out, _err, status = Open3.capture3(METADATA_BIN, 'ls')
      _(status.success?).must_equal true
      _(out).must_match(/^#{hash_prefix}\s+#{Regexp.escape(@socket)}\s+bash --norc --noprofile -i$/)
    end

    it 'ls: shows socket, name and cmd' do
      repl('set', 'name=shell')
      out, _err, status = Open3.capture3(METADATA_BIN, 'ls')
      _(status.success?).must_equal true
      _(out).must_match(/^#{hash_prefix}\s+#{Regexp.escape(@socket)}\s+shell\s+bash --norc --noprofile -i$/)
    end

    it 'ls -n: shows hash and socket only' do
      repl('set', 'name=shell')
      out, _err, status = Open3.capture3(METADATA_BIN, 'ls', '-n')
      _(status.success?).must_equal true
      _(out).must_match(/^#{hash_prefix}\s+#{Regexp.escape(@socket)}$/)
      _(out).wont_match(/shell/)
    end

    def digest
      Digest::MD5.hexdigest(@socket)
    end

    # The prefix ls shows: at least 4 characters of the socket digest.
    def hash_prefix
      "#{digest[0, 4]}[0-9a-f]*"
    end

    it 'ls: shows the hash prefix in the first column' do
      out, _err, _status = Open3.capture3(METADATA_BIN, 'ls')
      line = out.lines.find { |l| l.include?(@socket) }
      _(digest).must_be :start_with?, line.split.first
    end

    it '--socket: accepts a hash prefix instead of a path' do
      out, _err, status = Open3.capture3(
        METADATA_BIN, 'send', '--socket', digest[0, 12], stdin_data: "echo by-hash\n"
      )
      _(status.success?).must_equal true
      _(out).must_equal "by-hash\n"
    end

    it '--socket: rejects a hash prefix shorter than 4 characters' do
      _out, err, status = Open3.capture3(
        METADATA_BIN, 'send', '--socket', digest[0, 3], stdin_data: "echo x\n"
      )
      _(status.success?).must_equal false
      _(err).must_match(/too short/)
    end

    it 'REPL_SOCKET: selects the kernel by path or hash' do
      [@socket, digest[0, 12]].each do |ref|
        out, _err, status = Open3.capture3(
          { 'REPL_SOCKET' => ref }, METADATA_BIN, 'send', stdin_data: "echo env\n"
        )
        _(status.success?).must_equal true
        _(out).must_equal "env\n"
      end
    end

    it 'ls: shows a busy kernel with unknown name and cmd' do
      repl('post', stdin_data: "sleep 2\n")
      out, _err, status = Open3.capture3(METADATA_BIN, 'ls')
      _(status.success?).must_equal true
      _(out).must_match(/^#{hash_prefix}\s+#{Regexp.escape(@socket)}\s+\?\s+\?$/)

      # The abandoned query must not bring the server down.
      out, _err, status = repl('send', stdin_data: "echo alive\n")
      _(status.success?).must_equal true
      _(out).must_equal "alive\n"
    end
  end

  describe 'with --name and --no-caching' do
    before { start_kernel('--name', 'demo', '--no-caching') }

    it 'uses the given name and keeps only the last answer' do
      out, _err, _status = repl('get', 'name', 'caching')
      _(out).must_equal "name=demo\ncaching=off\n"

      repl('send', stdin_data: "echo one\n")
      first_id = repl('notebook', stdin_data: "echo two\n#=>\n#==\n").
        first[/#==\[([0-9]+)\]/, 1].to_i - 1
      _(repl('show').first).must_equal "two\n"
      _(repl('show', first_id.to_s)[2].success?).must_equal false
    end
  end
end

describe 'REPL::Server.flag' do
  it 'parses on/off values' do
    _(REPL::Server.flag('on')).must_equal true
    _(REPL::Server.flag('OFF')).must_equal false
    _(REPL::Server.flag('1')).must_equal true
    _(REPL::Server.flag('no')).must_equal false
    _ { REPL::Server.flag('maybe') }.must_raise RuntimeError
  end
end

describe 'REPL::Kernel#name' do
  it 'is empty by default' do
    _(REPL::Kernel.new(%w[/usr/bin/irb -f]).name).must_equal ''
  end

  it 'takes the given name' do
    _(REPL::Kernel.new(%w[bash], name: 'shell').name).must_equal 'shell'
  end
end

describe 'REPL::Server::Socket digest' do
  KernelSocket = REPL::Server::Socket

  # Two sockets whose digests share the first 4 characters.
  def colliding
    seen = {}
    (1..).each do |pid|
      socket = KernelSocket.new("/tmp/REPL.#{pid}.sock")
      other = seen[socket.digest[0, 4]]
      return [other, socket] if other
      seen[socket.digest[0, 4]] = socket
    end
  end

  it 'uses 4 characters when they are unique' do
    a, b = KernelSocket.new('/tmp/REPL.1.sock'), KernelSocket.new('/tmp/REPL.2.sock')
    _(a.prefix([a, b])).must_equal a.digest[0, 4]
  end

  it 'extends the prefix until it is unambiguous' do
    a, b = colliding
    _(a.prefix([a, b]).size).must_be :>, 4
    _(b.digest).wont_be :start_with?, a.prefix([a, b])
  end

  it 'resolves a unique prefix and rejects an ambiguous one' do
    a, b = colliding
    _(KernelSocket.resolve(a.prefix([a, b]), [a, b]).path).must_equal a.path
    _ { KernelSocket.resolve(a.digest[0, 4], [a, b]) }.must_raise RuntimeError
    _ { KernelSocket.resolve('ffffffffffff', [a, b]) }.must_raise RuntimeError
  end

  it 'takes anything with a slash for a path' do
    _(KernelSocket.resolve('/tmp/REPL.1.sock').path).must_equal '/tmp/REPL.1.sock'
  end
end
