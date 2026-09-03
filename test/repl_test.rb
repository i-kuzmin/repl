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

  # Shrugs off INT and TSTP, so a test can send them without racing the
  # kernel's death.
  PATIENT_REPL = <<~RUBY
    STDOUT.sync = true
    Signal.trap("INT") { }
    Signal.trap("TSTP") { }
    while STDIN.gets; end
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
    with_backend(SILENT_REPL, wait_timeout: 2.0, idle_timeout: 0.2) do |b|
      assert_equal '', b.execute('# just a comment')
      assert_equal '9', b.execute('x = 9')
      assert_equal '9', b.execute('x')
    end
  end

  # A non-echoing kernel whose answer happens to repeat the input must not
  # have that answer mistaken for an echo.
  def test_output_equal_to_input_is_kept_for_non_echoing_kernels
    with_backend(SILENT_REPL, wait_timeout: 2.0, idle_timeout: 0.2) do |b|
      assert_equal '7', b.execute('7')
      assert_equal '7', b.execute('7')
    end
  end

  def test_echo_is_stripped_when_answer_repeats_the_input
    with_backend(prompt: 'fake> ') do |b|
      assert_equal '7', b.execute('7')
      assert_equal '7', b.execute('7')
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

class SignalTest < Minitest::Test
  include TestHelpers

  # A REPL that blocks on `sleep` and survives SIGINT, like irb does.
  BLOCKING_REPL = <<~RUBY
    STDOUT.sync = true
    b = binding
    Signal.trap("INT") { raise Interrupt }
    while (line = STDIN.gets)
      begin
        puts eval(line, b).inspect
      rescue Interrupt
        puts "interrupted"
      rescue StandardError => e
        puts "ERR: \#{e.message}"
      end
    end
  RUBY

  def test_normalize_signal_accepts_names_and_control_characters
    n = Repl::Backend.method(:normalize_signal)
    assert_equal 'INT', n.call('INT')
    assert_equal 'INT', n.call('sigint')
    assert_equal 'INT', n.call('^C')
    assert_equal 'INT', n.call("\x03")
    assert_equal 'INT', n.call('ctrl-c')
    assert_equal 'TSTP', n.call('^Z')
    assert_equal 'QUIT', n.call("\x1C")
    assert_equal 'EOF', n.call('^D')
    assert_equal 'TERM', n.call('TERM')
  end

  def test_normalize_signal_rejects_nonsense
    assert_raises(Repl::Error) { Repl::Backend.normalize_signal('NOSUCHSIG') }
  end

  def test_signal_interrupts_a_blocking_command
    backend = Repl::Backend.new(fake_kernel(BLOCKING_REPL), wait_timeout: 5.0,
                                                            idle_timeout: 0.2)
    started = Time.now
    thread = Thread.new { backend.execute('sleep 30') }
    sleep 0.7
    assert_equal 'INT', backend.signal('^C')
    assert_equal 'interrupted', thread.value
    assert_operator Time.now - started, :<, 10
    # kernel is still usable afterwards
    assert_equal '4', backend.execute('2 + 2')
  ensure
    backend&.close
  end

  # A shell quits when it gets a SIGINT of its own, so Ctrl-C has to reach the
  # command it is running, exactly like the foreground job of a terminal.
  def test_interrupt_hits_the_kernels_job_and_spares_the_shell
    skip 'bash is not available' unless File.executable?('/bin/bash')

    # A test runner started as a background job ignores INT; children would
    # inherit that and become immune to the signal.
    previous = Signal.trap('INT', 'DEFAULT')
    backend = Repl::Backend.new(['/bin/bash'], wait_timeout: 2.0, idle_timeout: 0.2)
    Thread.new { backend.execute('sleep 30') }
    sleep 0.7
    assert_equal 'INT', backend.signal('^C')
    sleep 0.3
    assert_predicate backend, :alive?, 'the shell survives Ctrl-C'
    # answers again, i.e. the sleep is really gone
    assert_equal 'still here', backend.execute('echo still here')
  ensure
    Signal.trap('INT', previous || 'DEFAULT')
    backend&.close
  end

  def test_eof_closes_kernel_input
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    assert_equal 'EOF', backend.signal('^D')
    sleep 0.3
    refute_predicate backend, :alive?
  ensure
    backend&.close
  end

  def test_signal_on_dead_kernel_raises
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    backend.close
    assert_raises(Repl::Error) { backend.signal('INT') }
  end

  def test_kernel_runs_in_its_own_process_group
    with_backend(prompt: 'fake> ') do |b|
      assert_equal b.pid, Process.getpgid(b.pid)
    end
  end
end

class PostTest < Minitest::Test
  include TestHelpers

  def test_post_does_not_wait_for_output
    with_backend(prompt: 'fake> ') do |b|
      assert_equal 'a = 6 * 7', b.post('a = 6 * 7')
      assert_equal '42', b.execute('a')
    end
  end

  def test_answer_of_a_post_is_dropped_by_the_next_command
    with_backend(prompt: 'fake> ') do |b|
      b.post('6 * 7')
      assert_equal '2', b.execute('1 + 1')
    end
  end

  def test_post_ignores_blank_input
    with_backend(prompt: 'fake> ') do |b|
      assert_equal '', b.post("  \n")
    end
  end

  def test_post_on_dead_kernel_raises
    with_backend(prompt: 'fake> ') do |b|
      b.close
      assert_raises(Repl::Error) { b.post('1 + 1') }
    end
  end

  def test_post_over_the_socket_is_recorded
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    assert_equal 'posted', Repl::Client.post(server.socket_path, 'a = 1')
    assert_equal '1', Repl::Client.call(server.socket_path, 'a')
    assert_equal 'a = 1', server.history.tail(2).first.input
  ensure
    server&.stop
  end

  def test_post_feeds_a_command_that_is_still_running
    source = <<~RUBY
      STDOUT.sync = true
      while (line = STDIN.gets)
        puts line.chomp == "read" ? "got: \#{STDIN.gets.to_s.chomp}" : line.chomp
      end
    RUBY
    backend = Repl::Backend.new(fake_kernel(source), idle_timeout: 0.2, wait_timeout: 0.5)
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    asked = Thread.new { Repl::Client.call(server.socket_path, 'read') }
    sleep 0.3
    Repl::Client.post(server.socket_path, 'hello')
    assert_equal 'got: hello', asked.value.strip
  ensure
    server&.stop
  end
end

class EditorTest < Minitest::Test
  include TestHelpers

  # Runs the editor pipeline with a kernel stub that labels its answers.
  def craft(text, &block)
    block ||= ->(cmd) { "out(#{cmd})" }
    Repl::Editor.run(text, &block)
  end

  def test_markdown_fences_are_cut_off_before_feeding_the_kernel
    sent = []
    craft("```bash\nrepl_cmd\n```") { |c| sent << c; '' }
    assert_equal ['repl_cmd'], sent
    sent.clear
    craft("```bash\nrepl_cmd") { |c| sent << c; '' }
    assert_equal ['repl_cmd'], sent
    sent.clear
    craft("repl_cmd\n```") { |c| sent << c; '' }
    assert_equal ['repl_cmd'], sent
  end

  def test_fences_are_kept_in_the_crafted_output
    assert_equal "```bash\nls\n#=>\n# out(ls)\n#==\n```", craft("```bash\nls\n```")
  end

  def test_command_is_echoed_and_output_appended_without_markers
    assert_equal "1 + 1\n#=>\n# out(1 + 1)\n#==", craft('1 + 1')
  end

  def test_only_the_last_command_output_without_markers
    sent = []
    out = craft("a = 1\nb = 2") { |c| sent << c; 'answer' }
    assert_equal ["a = 1\nb = 2"], sent
    assert_equal "a = 1\nb = 2\n#=>\n# answer\n#==", out
  end

  def test_stale_output_between_markers_is_replaced
    text = "ls\n#=>\n# README.md  repl  test\n#==\n"
    assert_equal "ls\n#=>\n# out(ls)\n#==\n", craft(text)
  end

  def test_multiple_markers_split_the_input_into_commands
    sent = []
    text = "ls\n#=>\n# stale\n#==\nls -a\n#=>\n# stale\n#==\n"
    out = craft(text) { |c| sent << c; "#{c}!" }
    assert_equal ['ls', 'ls -a'], sent
    assert_equal "ls\n#=>\n# ls!\n#==\nls -a\n#=>\n# ls -a!\n#==\n", out
  end

  def test_missing_close_marker_ends_at_the_first_uncommented_line
    text = "a\n#=>\n# stale\nb\n#=>\n# stale\n"
    assert_equal "a\n#=>\n# out(a)\n#==\nb\n#=>\n# out(b)\n#==\n", craft(text)
  end

  def test_every_output_line_is_prefixed_with_a_hash
    out = craft('ls') { "one\ntwo\n\nthree" }
    assert_equal "ls\n#=>\n# one\n# two\n#\n# three\n#==", out
  end

  def test_empty_output_keeps_an_empty_block
    assert_equal "ls\n#=>\n#==", craft('ls') { '' }
  end

  def test_code_after_the_last_block_is_run_but_not_shown
    sent = []
    out = craft("a = 1\n#=>\n#==\nb = 2\n") { |c| sent << c; 'x' }
    assert_equal ['a = 1', "b = 2\n"].map(&:strip), sent.map(&:strip)
    assert_equal "a = 1\n#=>\n# x\n#==\nb = 2\n", out
  end

  def test_blank_lines_inside_a_block_are_kept_when_close_follows
    text = "a\n#=>\n# stale\n\n#==\nb\n"
    assert_equal "a\n#=>\n# out(a)\n#==\nb\n", craft(text)
  end

  def test_end_to_end_against_a_kernel
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    out = Repl::Editor.run("a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n") do |cmd|
      Repl::Client.call(server.socket_path, cmd)
    end
    assert_equal "a = [1,2,3]\n#=>\n# [1, 2, 3]\n#==\na[1]\n#=>\n# 2\n#==\n", out
  ensure
    server&.stop
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

  def test_signal_request_over_the_socket
    s = start_server
    assert_match(/sent SIGTSTP to pid #{s.backend.pid}/, Repl::Client.signal(s.socket_path, '^Z'))
    Repl::Client.signal(s.socket_path, 'CONT')
    assert_equal '1', Repl::Client.call(s.socket_path, '1')
  end

  def test_signal_is_recorded_in_history
    s = start_server
    Repl::Client.signal(s.socket_path, 'CONT')
    assert_equal '<signal CONT>', s.history.tail(1).first.input
  end

  def test_unknown_signal_returns_error
    s = start_server
    err = assert_raises(Repl::Error) { Repl::Client.signal(s.socket_path, 'NOPE') }
    assert_match(/unknown signal 'NOPE'/, err.message)
  end

  def test_signal_is_not_blocked_by_a_running_command
    backend = Repl::Backend.new(fake_kernel(SignalTest::BLOCKING_REPL),
                                wait_timeout: 5.0, idle_timeout: 0.2)
    @server = Repl::Server.new(backend, socket_path: tmp_socket,
                                        registry: tmp_registry, out: StringIO.new).start
    busy = Thread.new { Repl::Client.call(@server.socket_path, 'sleep 30') }
    sleep 0.7
    # served while the kernel is busy, i.e. without waiting for the lock
    assert_match(/sent SIGINT/, Repl::Client.signal(@server.socket_path, '^C'))
    assert_equal 'interrupted', busy.value
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

  def test_attach_with_argument_runs_one_command
    text, action = @server.admin_command('attach 6 * 7')
    assert_nil action
    assert_equal '42', text
    assert_equal 1, @server.history.stats[:requests]
  end

  def test_attach_without_argument_requests_attached_mode
    text, action = @server.admin_command('attach')
    assert_nil text
    assert_equal :attach, action
  end

  def test_attached_mode_executes_and_detaches
    @server.run_attached(StringIO.new("a = 21\na * 2\ndetach\n"))
    assert_match(/21\n/, @out.string)
    assert_match(/42\n/, @out.string)
    assert_match(/detached/, @out.string)
    assert_equal 2, @server.history.stats[:requests]
    assert_equal 3, @out.string.scan(@server.attach_prompt).size
  end

  def test_attached_prompt_names_the_kernel
    assert @server.attach_prompt.start_with?(File.basename(RbConfig.ruby))
  end

  def test_attached_mode_reports_empty_output_and_ignores_blank_lines
    backend = Repl::Backend.new([RbConfig.ruby, '-e', TestHelpers::SILENT_REPL],
                                wait_timeout: 2.0, idle_timeout: 0.2)
    out = StringIO.new
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: out).start
    server.run_attached(StringIO.new("# silent\n\n7\ndetach\n"))
    assert_match(/no output/, out.string)
    assert_match(/7\n/, out.string)
    assert_equal 2, server.history.stats[:requests]
  ensure
    server&.stop
  end

  def test_admin_attach_returns_to_admin_loop
    @server.run_admin(StringIO.new("attach\n1 + 1\ndetach\nstats\nquit\n"))
    assert_match(/2\n/, @out.string)
    assert_match(/requests: 1/, @out.string)
    refute File.exist?(@server.socket_path)
  end

  def test_attached_mode_ends_on_eof
    @server.run_attached(StringIO.new("1 + 1\n"))
    assert_match(/detached/, @out.string)
  end

  def test_interrupt_is_only_forwarded_while_attached
    refute_predicate @server, :attached?
    refute @server.forward_interrupt, 'outside attached mode the server stops instead'
  end

  def test_attached_mode_forwards_ctrl_c_to_the_kernel
    backend = Repl::Backend.new(fake_kernel(SignalTest::BLOCKING_REPL),
                                wait_timeout: 5.0, idle_timeout: 0.2)
    out = StringIO.new
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: out).start
    reader, writer = IO.pipe
    attached = Thread.new { server.run_attached(reader) }
    writer.puts('sleep 30')
    sleep 0.7
    assert_predicate server, :attached?
    assert server.forward_interrupt, 'the interrupt reaches the kernel'
    writer.puts('detach')
    attached.join(10)
    assert_match(/interrupted/, out.string)
    assert_predicate backend, :alive?
    refute_predicate server, :attached?
  ensure
    writer&.close
    reader&.close
    server&.stop
  end

  def test_forward_interrupt_declines_when_the_kernel_is_dead
    reader, writer = IO.pipe
    attached = Thread.new { @server.run_attached(reader) }
    writer.puts('1 + 1')
    sleep 0.3
    @server.admin_command('eof')
    sleep 0.3
    refute_predicate @server.backend, :alive?
    refute @server.forward_interrupt, 'a dead kernel cannot swallow the interrupt'
  ensure
    writer&.close
    attached&.join(5)
    reader&.close
  end

  def test_signal_admin_commands
    # a kernel that survives INT, so all commands can be checked in one go
    backend = Repl::Backend.new(fake_kernel(TestHelpers::PATIENT_REPL),
                                wait_timeout: 1.0, idle_timeout: 0.2)
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry,
                                       out: StringIO.new).start
    assert_match(/sent SIGTSTP/, server.admin_command('signal ^Z').first)
    assert_match(/sent SIGCONT/, server.admin_command('signal CONT').first)
    assert_match(/sent SIGINT/, server.admin_command('signal').first)
    assert_match(/sent SIGINT/, server.admin_command('interrupt').first)
    assert_match(/error: unknown signal 'BOGUS'/, server.admin_command('signal BOGUS').first)
    assert_predicate backend, :alive?
  ensure
    server&.stop
  end

  def test_eof_admin_command_stops_the_kernel
    assert_match(/closed kernel input/, @server.admin_command('eof').first)
    sleep 0.3
    refute_predicate @server.backend, :alive?
  end

  def test_help_lists_new_commands
    help = @server.admin_command('help').first
    assert_match(/attach/, help)
    assert_match(/signal/, help)
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

  def test_post_command_end_to_end
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    code, out, = cli(['post', '--socket', server.socket_path],
                     stdin: StringIO.new("a = 6 * 7\n"))
    assert_equal 0, code
    assert_equal '', out, 'post prints nothing'
    assert_equal "42\n", cli(['send', '--socket', server.socket_path, 'a'])[1]
  ensure
    server&.stop
  end

  def test_post_with_empty_input
    code, _out, err = cli(['post'], stdin: StringIO.new("  \n"))
    assert_equal 1, code
    assert_match(/nothing to send/, err)
  end

  def test_editor_send_command_end_to_end
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    text = "a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n"
    code, out, = cli(['editor-send', '--socket', server.socket_path],
                     stdin: StringIO.new(text))
    assert_equal 0, code
    assert_equal "a = [1,2,3]\n#=>\n# [1, 2, 3]\n#==\na[1]\n#=>\n# 2\n#==\n", out
  ensure
    server&.stop
  end

  def test_send_post_and_editor_send_accept_help
    %w[send post editor-send].each do |command|
      code, out, = cli([command, '--help'])
      assert_equal 0, code
      assert_match(/Usage:/, out)
    end
  end

  def test_signal_command_end_to_end
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    code, out, = cli(['signal', '--socket', server.socket_path, '^Z'])
    assert_equal 0, code
    assert_match(/sent SIGTSTP/, out)
    assert_match(/sent SIGCONT/, cli(['signal', '--socket', server.socket_path, 'CONT'])[1])
    # defaults to INT and finds the server through the registry
    assert_match(/sent SIGINT/, cli(['signal'])[1])
  ensure
    server&.stop
  end

  def test_signal_command_reports_unknown_signal
    backend = Repl::Backend.new(fake_kernel, prompt: 'fake> ')
    server = Repl::Server.new(backend, socket_path: tmp_socket,
                                       registry: tmp_registry, out: StringIO.new).start
    code, _out, err = cli(['signal', '--socket', server.socket_path, 'BOGUS'])
    assert_equal 1, code
    assert_match(/unknown signal/, err)
  ensure
    server&.stop
  end

  def test_signal_without_server
    code, _out, err = cli(['signal'])
    assert_equal 1, code
    assert_match(/no running server/, err)
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

    # a blocking command can be interrupted from another client
    blocked = Thread.new { run_send(env, socket, 'sleep 60') }
    sleep 1.5
    assert_match(/sent SIGINT/, run_cli(env, 'signal', '--socket', socket, '^C'))
    assert_match(/Abort|Interrupt/, blocked.value)
    assert_equal '4', run_send(env, socket, '2 + 2')

    # admin console can talk to the kernel directly
    stdin.puts('attach a.size')
    assert_match(/3\z/, stdout.readline.strip)
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

  def run_cli(env, *args)
    out, status = Open3.capture2e(env, RbConfig.ruby, BIN, *args)
    assert_predicate status, :success?, "repl #{args.join(' ')} failed: #{out}"
    out.strip
  end

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
