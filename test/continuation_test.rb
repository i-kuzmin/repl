# frozen_string_literal: true
#
# Multi-line commands. Input is fed to the kernel one line at a time, so a line
# that does not complete a command leaves the kernel at a continuation prompt.
# Those prompts are not matched by shape - they differ per kernel and even per
# construct (bash '> ', irb '...002* ' inside a block but '...006" ' inside a
# string) - but by where they leave the cursor: on an unfinished line. The
# corner cases below are the ones that tell such a prompt apart from a kernel
# that is merely slow, and from output that has not ended in a newline yet.
require 'minitest/autorun'
require 'open3'
require 'timeout'

load File.expand_path('../repl', __dir__)

REPL_BIN = File.expand_path('../repl', __dir__) unless defined?(REPL_BIN)

describe 'continuation prompts (bash)' do
  let(:kernel) do
    REPL::Kernel.new(%w[bash --norc --noprofile -i], silent: true)
                .tap { |k| k.start }
  end

  after { kernel.stop }

  def send_line(line)
    kernel.recive_response_for "#{line}\n"
  end

  it 'reports an unfinished block as continued' do
    send_line 'if true; then'
    _(kernel.continued?).must_equal true
  end

  it 'completes the block on its closing line' do
    send_line 'if true; then'
    send_line 'echo one'
    out = send_line 'fi'
    _(kernel.continued?).must_equal false
    _(out).must_match(/one/)
  end

  it 'treats a heredoc body as a continuation' do
    send_line 'cat <<EOF'
    _(kernel.continued?).must_equal true
    send_line 'body'
    _(kernel.continued?).must_equal true
    out = send_line 'EOF'
    _(kernel.continued?).must_equal false
    _(out).must_match(/body/)
  end

  # The failure this guards against: a slow command is also silent, so silence
  # alone must not be read as a prompt or the next line would be fed into it.
  it 'does not mistake a slow command for a continuation' do
    out = send_line 'sleep 1; echo woke'
    _(kernel.continued?).must_equal false
    _(out).must_match(/woke/)
  end

  # Output without a trailing newline leaves the prompt glued to it, which is
  # what an unanchored prompt pattern is for.
  it 'ends a command whose output has no trailing newline' do
    send_line "printf 'no-newline'"
    _(kernel.continued?).must_equal false
  end

  it 'returns to a normal prompt after an abandoned command' do
    send_line 'if true; then'
    _(kernel.continued?).must_equal true
    kernel.abandon
    _(send_line('echo alive')).must_match(/alive/)
    _(kernel.continued?).must_equal false
  end
end

describe 'continuation prompts (irb)' do
  let(:kernel) { REPL::Kernel.new(%w[irb], silent: true).tap { |k| k.start } }

  after { kernel.stop }

  def send_line(line)
    kernel.recive_response_for "#{line}\n"
  end

  # irb marks an open block with '*' where the normal prompt has '>'.
  it 'reports an open block as continued' do
    send_line 'def foo'
    _(kernel.continued?).must_equal true
    send_line '42'
    _(kernel.continued?).must_equal true
    _(send_line('end')).must_match(/:foo/)
    _(kernel.continued?).must_equal false
  end

  # An unterminated string uses a different marker again ('"'), which is why
  # continuation is not detected by matching a second known prompt.
  it 'reports an unterminated string as continued' do
    send_line '"abc'
    _(kernel.continued?).must_equal true
    _(send_line('x"')).must_match(/abc/)
    _(kernel.continued?).must_equal false
  end
end

describe 'multi-line commands over the socket' do
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
    Open3.capture3(REPL_BIN, 'send', '--socket', @socket, stdin_data: data)
  end

  it 'answers a multi-line block with the output of the block' do
    out, _err, status = send_stdin "if true; then\necho one\nfi\n"
    _(status.success?).must_equal true
    _(out).must_equal "one\n"
  end

  it 'keeps a heredoc body out of the answer' do
    out, _err, status = send_stdin "cat <<EOF\nbody\nEOF\n"
    _(status.success?).must_equal true
    _(out).must_equal "body\n"
  end

  it 'concatenates the answers of independent commands' do
    out, _err, status = send_stdin "echo one\necho two\n"
    _(status.success?).must_equal true
    _(out).must_equal "one\ntwo\n"
  end

  # An incomplete request must not leave the kernel waiting, or the next
  # request would be read as the rest of it.
  it 'recovers from a request that is left incomplete' do
    send_stdin "if true; then\n"
    out, _err, status = send_stdin "echo alive\n"
    _(status.success?).must_equal true
    _(out).must_equal "alive\n"
  end
end
