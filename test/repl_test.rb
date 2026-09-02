# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require 'fileutils'

load File.expand_path('../repl', __dir__)

module TestHelpers
  # A tiny persistent REPL used instead of irb: fast, deterministic and it
  # behaves like a real one (echoes input, keeps state, prints a prompt).
  FAKE_REPL = <<~RUBY
    STDOUT.sync = true
    b = binding
    print "fake> "
    while (line = STDIN.gets)
      puts line.chomp
      begin
        puts eval(line, b).inspect
      rescue StandardError => e
        puts "ERR: \#{e.message}"
      end
      print "fake> "
    end
  RUBY

  # No prompt, no echo, and silent for comments: exercises idle mode.
  SILENT_REPL = <<~RUBY
    STDOUT.sync = true
    b = binding
    while (line = STDIN.gets)
      next if line.start_with?("#")
      begin
        puts eval(line, b).inspect
      rescue StandardError => e
        puts "ERR: \#{e.message}"
      end
    end
  RUBY

  def fake_kernel(source = FAKE_REPL)
    [RbConfig.ruby, '-e', source]
  end

  def with_backend(source = FAKE_REPL, **opts)
    backend = Repl::Backend.new(fake_kernel(source), **opts)
    yield backend
  ensure
    backend&.close
  end

  def tmp_registry
    Repl::Registry.new(File.join(@tmpdir, 'servers.json'))
  end

  def tmp_socket
    File.join(@tmpdir, "sock-#{SecureRandom.hex(4)}")
  end

  def setup
    @tmpdir = Dir.mktmpdir('repl-test')
    @saved_env = { 'REPL_SOCKET' => ENV['REPL_SOCKET'], 'REPL_HOME' => ENV['REPL_HOME'] }
    ENV['REPL_SOCKET'] = nil
    ENV['REPL_HOME'] = @tmpdir
  end

  def teardown
    @saved_env.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end
end

class BackendTest < Minitest::Test
  include TestHelpers

  def test_executes_command_and_returns_output
    with_backend(prompt: 'fake> ') do |b|
      assert_equal '[1, 2, 3]', b.execute('[1,2,3]')
    end
  end

  def test_state_persists_between_calls
    with_backend(prompt: 'fake> ') do |b|
      b.execute('a = [1,2,3]')
      assert_equal '2', b.execute('a[1]')
      assert_equal '3', b.execute('a.size')
    end
  end

  def test_strips_echoed_input_and_prompt
    with_backend(prompt: 'fake> ') do |b|
      out = b.execute('40 + 2')
      assert_equal '42', out
      refute_includes out, '40 + 2'
      refute_includes out, 'fake>'
    end
  end

  def test_marker_mode
    with_backend(marker: 'puts "%s"') do |b|
      assert_equal '7', b.execute('3 + 4')
      assert_equal '7', b.execute('3 + 4')
    end
  end

  def test_marker_mode_removes_token_lines
    with_backend(marker: 'puts "%s"') do |b|
      refute_match(/REPL-/, b.execute('1 + 1'))
    end
  end

  def test_marker_mode_waits_for_slow_commands
    with_backend(marker: 'puts "%s"', timeout: 10) do |b|
      assert_equal '"slow"', b.execute('sleep 0.6; "slow"')
    end
  end

  def test_idle_mode_without_prompt_or_marker
    with_backend(SILENT_REPL, wait_timeout: 2.0, idle_timeout: 0.2) do |b|
      assert_equal '5', b.execute('2 + 3')
    end
  end

  def test_silent_command_returns_empty_output
    with_backend(SILENT_REPL, wait_timeout: 0.4, idle_timeout: 0.2) do |b|
      assert_equal '', b.execute('# just a comment')
      assert_equal '9', b.execute('x = 9')
      assert_equal '9', b.execute('x')
    end
  end

  def test_blank_input_is_not_sent
    with_backend(prompt: 'fake> ') do |b|
      assert_equal '', b.execute("  \n ")
    end
  end

  def test_multiline_output_is_preserved
    with_backend(marker: 'puts "%s"') do |b|
      assert_equal "one\ntwo\nnil", b.execute('puts "one"; puts "two"')
    end
  end

  def test_errors_are_returned_as_output
    with_backend(prompt: 'fake> ') do |b|
      assert_match(/ERR: boom/, b.execute("raise 'boom'"))
    end
  end

  def test_alive_and_close
    b = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    assert_predicate b, :alive?
    assert_operator b.pid, :>, 0
    b.close
    refute_predicate b, :alive?
  end

  def test_execute_after_close_raises
    b = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    b.close
    assert_raises(Repl::Error) { b.execute('1') }
  end

  def test_unknown_kernel_command_raises
    assert_raises(Repl::Error) { Repl::Backend.new(['definitely-not-a-real-binary-xyz']) }
  end

  def test_empty_command_raises
    assert_raises(Repl::Error) { Repl::Backend.new([]) }
  end
end

class HistoryTest < Minitest::Test
  include TestHelpers

  def test_records_and_tails
    h = Repl::History.new
    h.record('a', '1')
    h.record('b', '2')
    assert_equal %w[a b], h.tail(10).map(&:input)
    assert_equal %w[2], h.tail(1).map(&:output)
  end

  def test_tail_defaults_and_empty
    assert_empty Repl::History.new.tail
  end

  def test_respects_limit
    h = Repl::History.new(2)
    3.times { |i| h.record("in#{i}", "out#{i}") }
    assert_equal 2, h.size
    assert_equal %w[in1 in2], h.tail(10).map(&:input)
  end

  def test_stats_counts_all_traffic_even_beyond_limit
    h = Repl::History.new(1)
    h.record('abc', 'de')
    h.record('f', 'ghij')
    s = h.stats
    assert_equal 2, s[:requests]
    assert_equal 4, s[:in_bytes]
    assert_equal 6, s[:out_bytes]
    assert_equal 1, s[:stored]
    assert_operator s[:uptime], :>=, 0
  end
end

class RegistryTest < Minitest::Test
  include TestHelpers

  def make_socket
    path = tmp_socket
    [UNIXServer.new(path), path]
  end

  def test_register_and_list
    server, path = make_socket
    r = tmp_registry
    r.register(socket: path, pid: Process.pid, command: %w[irb --fast])
    entries = r.servers
    assert_equal 1, entries.size
    assert_equal path, entries.first['socket']
    assert_equal 'irb --fast', entries.first['command']
  ensure
    server&.close
  end

  def test_unregister
    server, path = make_socket
    r = tmp_registry
    r.register(socket: path, pid: Process.pid, command: ['irb'])
    r.unregister(path)
    assert_empty r.servers
  ensure
    server&.close
  end

  def test_prunes_dead_entries
    server, path = make_socket
    r = tmp_registry
    r.register(socket: File.join(@tmpdir, 'gone'), pid: Process.pid, command: ['irb'])
    r.register(socket: path, pid: 0x7FFFFFFF, command: ['irb'])
    assert_empty r.servers
  ensure
    server&.close
  end

  def test_registering_same_socket_twice_keeps_one_entry
    server, path = make_socket
    r = tmp_registry
    2.times { r.register(socket: path, pid: Process.pid, command: ['irb']) }
    assert_equal 1, r.servers.size
  ensure
    server&.close
  end

  def test_survives_corrupted_file
    File.write(File.join(@tmpdir, 'servers.json'), 'not json at all')
    assert_empty tmp_registry.servers
  end

  def test_default_path_follows_repl_home
    assert_equal File.join(@tmpdir, 'servers.json'), Repl::Registry.default_path
  end
end

class ServerTest < Minitest::Test
  include TestHelpers

  def start_server
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    @server = Repl::Server.new(backend, socket_path: tmp_socket,
                                        registry: tmp_registry,
                                        out: StringIO.new)
    @server.start
  end

  def teardown
    @server&.stop
    super
  end

  def test_creates_socket_and_registers
    s = start_server
    assert File.socket?(s.socket_path)
    assert_predicate s, :running?
    assert_equal 1, tmp_registry.servers.size
  end

  def test_client_round_trip
    s = start_server
    assert_equal '[1, 2, 3]', Repl::Client.call(s.socket_path, 'a = [1,2,3]')
    assert_equal '2', Repl::Client.call(s.socket_path, 'a[1]')
  end

  def test_history_is_recorded
    s = start_server
    Repl::Client.call(s.socket_path, '1 + 1')
    assert_equal 1, s.history.stats[:requests]
    assert_equal '1 + 1', s.history.tail(1).first.input
  end

  def test_concurrent_clients_are_serialised
    s = start_server
    results = 5.times.map do |i|
      Thread.new { Repl::Client.call(s.socket_path, "#{i} + 100") }
    end.map(&:value)
    assert_equal %w[100 101 102 103 104], results
  end

  def test_malformed_request_returns_error
    s = start_server
    UNIXSocket.open(s.socket_path) do |sock|
      sock.puts('this is not json')
      assert_match(/invalid JSON/, JSON.parse(sock.gets)['error'])
    end
  end

  def test_request_without_cmd_returns_error
    s = start_server
    UNIXSocket.open(s.socket_path) do |sock|
      sock.puts(JSON.generate('nope' => 1))
      assert_match(/"cmd" is missing/, JSON.parse(sock.gets)['error'])
    end
  end

  def test_stop_cleans_up
    s = start_server
    path = s.socket_path
    s.stop
    refute File.exist?(path)
    assert_empty tmp_registry.servers
    refute_predicate s.backend, :alive?
  end

  def test_stop_is_idempotent
    s = start_server
    s.stop
    s.stop
  end

  def test_client_error_when_socket_missing
    assert_raises(Repl::Error) { Repl::Client.call(File.join(@tmpdir, 'nope'), 'x') }
  end

  def test_generated_socket_path_matches_readme_shape
    assert_match(%r{/repl-kernel-[A-Z]{7}\z}, Repl::Server.generate_socket_path)
  end
end

class AdminConsoleTest < Minitest::Test
  include TestHelpers

  def setup
    super
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    @out = StringIO.new
    @server = Repl::Server.new(backend, socket_path: tmp_socket,
                                        registry: tmp_registry, out: @out,
                                        prompt: '$$ ')
    @server.start
  end

  def teardown
    @server&.stop
    super
  end

  def test_quit_and_close_stop_the_server
    %w[quit close exit].each do |cmd|
      text, halt = @server.admin_command(cmd)
      assert halt, "#{cmd} should stop the server"
      assert_match(/stopping/, text)
    end
  end

  def test_stats_reports_traffic
    Repl::Client.call(@server.socket_path, '1 + 1')
    text, halt = @server.admin_command('stats')
    refute halt
    assert_match(/requests: 1/, text)
    assert_match(/in: *5 bytes/, text)
    assert_match(/socket: *#{Regexp.escape(@server.socket_path)}/, text)
  end

  def test_tail_shows_latest_messages
    Repl::Client.call(@server.socket_path, '"first"')
    Repl::Client.call(@server.socket_path, '"second"')
    text, = @server.admin_command('tail 1')
    refute_match(/first/, text)
    assert_match(/second/, text)
  end

  def test_tail_when_empty
    text, = @server.admin_command('tail')
    assert_match(/no messages/, text)
  end

  def test_tail_flattens_multiline_messages
    Repl::Client.call(@server.socket_path, 'puts "x"; puts "y"')
    text, = @server.admin_command('tail')
    refute_match(/^x$/, text)
    assert_match(/⏎/, text)
  end

  def test_help_and_unknown_and_blank
    assert_match(/admin commands/, @server.admin_command('help').first)
    assert_match(/unknown command 'wat'/, @server.admin_command('wat').first)
    assert_nil @server.admin_command('   ').first
  end

  def test_run_admin_loop_prompts_and_exits_on_quit
    @server.run_admin(StringIO.new("stats\nquit\n"))
    assert_equal 2, @out.string.scan('$$ ').size
    assert_match(/requests: 0/, @out.string)
    refute File.exist?(@server.socket_path)
  end

  def test_run_admin_exits_on_eof
    @server.run_admin(StringIO.new(''))
    refute File.exist?(@server.socket_path)
  end
end

class CLITest < Minitest::Test
  include TestHelpers

  def cli(args, stdin: StringIO.new(''))
    out = StringIO.new
    err = StringIO.new
    code = Repl::CLI.new(args, out: out, err: err, stdin: stdin,
                               registry: tmp_registry).run
    [code, out.string, err.string]
  end

  def test_help_and_version
    code, out, = cli([])
    assert_equal 0, code
    assert_match(/Usage:/, out)
    assert_match(/repl #{Repl::VERSION}/, cli(['version'])[1])
    assert_match(/Usage:/, cli(['help'])[1])
  end

  def test_unknown_command
    code, _out, err = cli(['bogus'])
    assert_equal 1, code
    assert_match(/unknown command 'bogus'/, err)
  end

  def test_kernel_requires_a_command
    code, _out, err = cli(['kernel'])
    assert_equal 1, code
    assert_match(/kernel command is required/, err)
  end

  def test_send_without_server
    code, _out, err = cli(['send'], stdin: StringIO.new("1+1\n"))
    assert_equal 1, code
    assert_match(/no running server/, err)
  end

  def test_send_with_empty_input
    code, _out, err = cli(['send'], stdin: StringIO.new("  \n"))
    assert_equal 1, code
    assert_match(/nothing to send/, err)
  end

  def test_resolve_socket_prefers_explicit_then_env_then_registry
    c = Repl::CLI.new([], registry: tmp_registry)
    ENV['REPL_SOCKET'] = '/from/env'
    assert_equal '/explicit', c.resolve_socket('/explicit')
    assert_equal '/from/env', c.resolve_socket(nil)
    ENV['REPL_SOCKET'] = nil
    path = tmp_socket
    server = UNIXServer.new(path)
    tmp_registry.register(socket: path, pid: Process.pid, command: ['irb'])
    assert_equal path, c.resolve_socket(nil)
  ensure
    server&.close
  end

  def test_resolve_socket_is_ambiguous_with_two_servers
    servers = 2.times.map do
      path = tmp_socket
      tmp_registry.register(socket: path, pid: Process.pid, command: ['irb'])
      UNIXServer.new(path)
    end
    err = assert_raises(Repl::Error) do
      Repl::CLI.new([], registry: tmp_registry).resolve_socket(nil)
    end
    assert_match(/several servers/, err.message)
  ensure
    servers&.each(&:close)
  end

  def test_list_command
    assert_match(/no running servers/, cli(['list'])[1])
    path = tmp_socket
    server = UNIXServer.new(path)
    tmp_registry.register(socket: path, pid: Process.pid, command: %w[irb])
    assert_match(/#{Regexp.escape(path)}\tirb\tpid #{Process.pid}/, cli(['list'])[1])
  ensure
    server&.close
  end

  def test_send_end_to_end_with_explicit_socket
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    code, out, = cli(['send', '--socket', server.socket_path],
                     stdin: StringIO.new("a = 6 * 7\n"))
    assert_equal 0, code
    assert_equal "42\n", out
    assert_equal "42\n", cli(['send', '--socket', server.socket_path, 'a'])[1]
  ensure
    server&.stop
  end
end

# End-to-end run of the real executable with a real irb kernel.
class ExecutableTest < Minitest::Test
  include TestHelpers

  BIN = File.expand_path('../repl', __dir__)

  def test_kernel_and_send_via_shell
    skip 'irb not available' unless system('which irb > /dev/null 2>&1')

    socket = tmp_socket
    env = { 'REPL_HOME' => @tmpdir }
    stdin, stdout, thread = Open3.popen2e(
      env, RbConfig.ruby, BIN, 'kernel', '--socket', socket,
      '--marker', 'puts "%s"', 'irb'
    )
    banner = stdout.readline
    assert_match(/Starting kernel 'irb' on socket '#{Regexp.escape(socket)}'/, banner)
    wait_for { File.socket?(socket) }

    assert_equal '[1, 2, 3]', run_send(env, socket, 'a = [1,2,3]')
    assert_equal '2', run_send(env, socket, 'a[1]')
    # no --socket: resolved through the registry
    assert_equal '3', run_send(env, nil, 'a.size')

    stdin.puts('stats')
    stdin.puts('quit')
    stdin.close
    thread.join(15)
    refute File.exist?(socket), 'socket should be removed on quit'
  ensure
    stdin.close if stdin && !stdin.closed?
    Process.kill('KILL', thread.pid) if thread&.alive?
  end

  private

  def run_send(env, socket, input)
    args = ['send']
    args += ['--socket', socket] if socket
    out, status = Open3.capture2e(env, RbConfig.ruby, BIN, *args, stdin_data: input)
    assert_predicate status, :success?, "repl send failed: #{out}"
    out.strip
  end

  def wait_for(timeout = 15)
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now > deadline
    raise 'timed out waiting for condition' unless yield
  end
end
