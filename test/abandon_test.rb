# frozen_string_literal: true
#
# Abandoning a command that never completed. What is in the way decides how it
# has to be ended, and the terminal says which of the two it is: while the
# kernel waits for the rest of a multi-line command it owns the terminal
# itself and an interrupt ends that, but a program it started - a pager, an
# editor, anything reading from the terminal - owns the terminal instead and
# is signalled directly.
#
# The cases below are the ones a keystroke cannot cover: 'q' ends a pager but
# is read as input by `cat`, and a program that ignores SIGINT ignores ^C.
require 'minitest/autorun'
require 'open3'
require 'timeout'

load File.expand_path('../repl', __dir__)

REPL_BIN = File.expand_path('../repl', __dir__) unless defined?(REPL_BIN)

describe 'abandoning a command' do
  let(:kernel) do
    REPL::Kernel.new(%w[bash --norc --noprofile -i], silent: true)
                .tap { |k| k.start }
  end

  after { kernel.stop }

  def send_line(line)
    kernel.recive_response_for "#{line}\n"
  end

  def pgid
    Process.getpgid kernel.pid
  end

  # The kernel is the one reading, so the terminal belongs to it and an
  # interrupt is what ends the wait.
  it 'keeps the terminal while waiting for the rest of a command' do
    send_line 'if true; then'
    _(kernel.continued?).must_equal true
    _(kernel.foreground_pgid).must_equal pgid
  end

  it 'ends an unfinished command without killing the kernel' do
    send_line 'if true; then'
    kernel.abandon
    _(kernel.continued?).must_equal false
    _(kernel.foreground_pgid).must_equal pgid
    _(send_line('echo alive')).must_match(/alive/)
  end

  # A program started by the kernel takes the terminal over, which is what
  # tells this case apart from the one above.
  it 'hands the terminal to a program that reads from it' do
    send_line "printf 'READING: '; cat"
    _(kernel.continued?).must_equal true
    _(kernel.foreground_pgid).wont_equal pgid
  end

  # `cat` has no quit key: a 'q' is read as input and it goes on waiting, so
  # only a signal ends it.
  it 'ends a program that has no quit key' do
    send_line "printf 'READING: '; cat"
    kernel.abandon
    _(kernel.continued?).must_equal false
    _(kernel.foreground_pgid).must_equal pgid
    _(send_line('echo alive')).must_match(/alive/)
  end

  # Nothing typed at it would end this one: it ignores the interrupt ^C
  # delivers, and SIGTERM as well, so it has to be killed outright.
  it 'kills a program that ignores being interrupted and terminated' do
    send_line %q{bash -c 'trap "" INT TERM; printf "STUCK: "; read x'}
    _(kernel.continued?).must_equal true
    stuck = kernel.foreground_pgid
    _(stuck).wont_equal pgid

    kernel.abandon
    _(kernel.continued?).must_equal false
    _(kernel.foreground_pgid).must_equal pgid
    _(send_line('echo alive')).must_match(/alive/)
    _(alive?(stuck)).must_equal false
  end

  # The echo is switched off at the terminal once, at startup; a program that
  # was killed before it could put the terminal back must not leave it on, or
  # every answer would come back with the request in front of it.
  it 'leaves the terminal as the kernel needs it' do
    send_line "printf 'READING: '; cat"
    kernel.abandon
    out = send_line 'echo alive'
    _(out).must_match(/alive/)
    _(out).wont_match(/echo alive/)
  end

  def alive?(pgid)
    Process.kill 0, -pgid
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
end

describe 'abandoning a pager' do
  let(:kernel) do
    REPL::Kernel.new(%w[bash --norc --noprofile -i], silent: true)
                .tap { |k| k.start }
  end

  after { kernel.stop }

  def send_line(line)
    kernel.recive_response_for "#{line}\n"
  end

  # The case this started from: `man` leaves a pager in front of the kernel,
  # and the pager ignores the interrupt, so every request that followed was
  # typed into the pager instead of the kernel.
  it 'recovers the kernel from a pager' do
    skip 'no pager available' unless system('command -v less > /dev/null 2>&1')

    send_line 'seq 1 500 | less'
    _(kernel.continued?).must_equal true
    _(kernel.foreground_pgid).wont_equal Process.getpgid(kernel.pid)

    kernel.abandon
    _(kernel.continued?).must_equal false
    out = send_line 'echo alive'
    _(out).must_match(/alive/)
    _(out).wont_match(/echo alive/)
  end
end

describe 'abandoning over the socket' do
  before do
    @server_pid = Process.spawn(
      REPL_BIN, 'kernel', 'bash', '--norc', '--noprofile', '-i',
      in: File::NULL, out: File::NULL, err: File::NULL
    )
    @socket = "/tmp/REPL.#{@server_pid}.sock"
    Timeout.timeout(10) { sleep 0.05 until File.exist?(@socket) }
  end

  after do
    Process.kill('TERM', @server_pid)
    Process.wait(@server_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  ensure
    File.unlink(@socket) if File.exist?(@socket)
  end

  def send_stdin(data)
    Timeout.timeout(30) do
      Open3.capture3(REPL_BIN, 'send', '--socket', @socket, stdin_data: data)
    end
  end

  # A request that leaves a program in front of the kernel must not take the
  # requests that follow with it.
  it 'answers the next request after a request left a pager behind' do
    skip 'no pager available' unless system('command -v less > /dev/null 2>&1')

    send_stdin "seq 1 500 | less\n"
    out, _err, status = send_stdin "echo alive\n"
    _(status.success?).must_equal true
    _(out).must_equal "alive\n"
  end

  it 'answers the next request after a request left a reader behind' do
    send_stdin "printf 'READING: '; cat\n"
    out, _err, status = send_stdin "echo alive\n"
    _(status.success?).must_equal true
    _(out).must_equal "alive\n"
  end
end
