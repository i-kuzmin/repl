# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'tempfile'

load File.expand_path('../repl', __dir__)

module REPL

# A colored bash prompt as it really arrives from a PTY:
# OSC title, SGR colors and the bracketed-paste toggle printed after it.
COLORED = "\e]0;me@host: ~\a\e[01;32mme@host\e[00m:\e[01;34m~/src\e[00m$ \e[?2004h"

describe 'Terminal.render' do
  it 'strips escape sequences and keeps the text' do
    _(REPL::Terminal.render(COLORED)).must_equal 'me@host:~/src$ '
  end

  it 'strips a sequence cut by a read boundary' do
    _(REPL::Terminal.render("ok\n\e[01;3")).must_equal "ok\n"
  end

  it 'keeps newlines and drops CR and other control characters' do
    _(REPL::Terminal.render("a\r\nb\ac")).must_equal "a\nbc"
  end

  # Real capture of irb answering "1 + 1": Reline draws the input line, then
  # refreshes it, each pass preceded by "\e[1G" (column 1) and "\e[K" (erase).
  RELINE = "\e[1G\e[1G>> 1 + 1\e[K\e[1G\e[9G\e[1G>> 1 + 1\e[K\e[1G\e[1G" \
           "\e[1B\e[1G\e[K\e[1G=> 2\r\n\e[6n\e[1G>> \e[K\e[1G\e[4G"

  it 'overwrites a redrawn line instead of repeating it' do
    _(REPL::Terminal.render(RELINE)).must_equal ">> 1 + 1\n=> 2\n>> "
  end

  it 'overwrites the width probe irb prints before its prompt' do
    _(REPL::Terminal.render("\e[1G\u25BD\e[6n\e[1Girb(main):001:0> "))
      .must_equal 'irb(main):001:0> '
  end

  it 'applies carriage return as an overwrite' do
    _(REPL::Terminal.render("50%\r100%")).must_equal '100%'
  end

  it 'applies backspace' do
    _(REPL::Terminal.render("abc\b\bX")).must_equal 'aXc'
  end
end

describe 'Kernel.detect_prompt' do
  let(:prompt) { REPL::Kernel.detect_prompt REPL::Terminal.render(COLORED) }

  it 'matches the prompt at the end of the output' do
    _(prompt.match?("hello\nme@host:~/src$ ")).must_equal true
  end

  it 'ignores prompt-looking lines inside the output' do
    _(prompt.match?("me@host:~/src$ \nstill running")).must_equal false
  end

  it 'generalizes counters (irb)' do
    p2 = REPL::Kernel.detect_prompt 'irb(main):001> '
    _(p2.match?("=> 1\nirb(main):002> ")).must_equal true
  end

  it 'returns nil when there is no prompt' do
    _(REPL::Kernel.detect_prompt("banner\n")).must_be_nil
  end

  # printf & co. leave no trailing newline, so the prompt that follows is glued
  # to the output. A prompt anchored to a line start is never found there and
  # the response would never be recognized as finished.
  it 'matches a prompt glued to output that ends without a newline' do
    _(prompt.match?('10 20 endme@host:~/src$ ')).must_equal true
  end
end

describe 'Kernel' do
  let(:kernel) do
    REPL::Kernel.new(%w[bash --norc --noprofile -i], silent: true).tap { |k| k.start }
  end

  after { kernel.stop }

  it 'detects the prompt at startup' do
    _(kernel.prompt).wont_be_nil
  end

  it 'reads a response back' do
    kernel.send "echo hello\n"
    _(kernel.recive_response).must_match(/hello/)
  end

  it 'waits for a slow command instead of returning early' do
    kernel.send "sleep 1; echo woke\n"
    _(kernel.recive_response).must_match(/woke/)
  end
end

describe 'Kernel output' do
  after { @kernel.stop if @kernel }

  it 'resolves stdout/- to $stdout' do
    _(REPL::Kernel.resolve_output('stdout')).must_equal $stdout
    _(REPL::Kernel.resolve_output('-')).must_equal $stdout
  end

  it 'defaults to echoing to $stdout' do
    @kernel = REPL::Kernel.new(%w[bash --norc --noprofile -i]).tap { |k| k.start }
    _(@kernel.output).must_equal $stdout
  end

  it 'echoes to an IO given at construction time instead of $stdout' do
    io = StringIO.new
    @kernel = REPL::Kernel.new(%w[bash --norc --noprofile -i], output: io).tap { |k| k.start }
    @kernel.send "echo hello\n"
    @kernel.recive_response
    _(io.string).must_match(/hello/)
  end

  it 'redirects to a path given as a String, appending to the file' do
    Tempfile.create('repl-output') do |file|
      @kernel = REPL::Kernel.new(%w[bash --norc --noprofile -i]).tap { |k| k.start }
      @kernel.output = file.path
      @kernel.send "echo hello\n"
      @kernel.recive_response
      _(File.read(file.path)).must_match(/hello/)
    end
  end

  it 'closes a file it opened itself when redirected elsewhere' do
    Tempfile.create('repl-output') do |file|
      @kernel = REPL::Kernel.new(%w[bash --norc --noprofile -i]).tap { |k| k.start }
      @kernel.output = file.path
      opened = @kernel.output
      @kernel.output = 'stdout'
      _(opened.closed?).must_equal true
      _(@kernel.output).must_equal $stdout
    end
  end

  it 'does not close an IO handed to it directly (not opened by the kernel)' do
    io = StringIO.new
    @kernel = REPL::Kernel.new(%w[bash --norc --noprofile -i], output: io).tap { |k| k.start }
    @kernel.output = 'stdout'
    _(io.closed?).must_equal false
    _(@kernel.output).must_equal $stdout
  end
end

end

describe 'Kernel with a line editor (irb)' do
  let(:kernel) { REPL::Kernel.new(%w[irb], silent: true).tap { |k| k.start } }

  after { kernel.stop }

  # Without an answer to "\e[6n" Reline blocks and irb never prints a prompt.
  it 'answers the cursor position request and detects the prompt' do
    _(kernel.prompt).wont_be_nil
  end

  it 'reads a response back' do
    kernel.send "1 + 1\n"
    _(kernel.recive_response).must_match(/=> 2/)
  end
end

describe 'Terminal replies' do
  # "\e[6n" asks for the cursor position; Reline blocks until it is answered.
  it 'answers a cursor position request with the current column' do
    t = REPL::Terminal.new
    t.write "abc\e[6n"
    _(t.replies).must_equal ["\e[1;4R"]
  end

  it 'answers each request once' do
    t = REPL::Terminal.new
    t.write "\e[6n"
    t.replies
    t.write 'x'
    _(t.replies).must_be_empty
  end

  it 'answers a request split between two chunks' do
    t = REPL::Terminal.new
    t.write "\e[6"
    _(t.replies).must_be_empty
    t.write 'n'
    _(t.replies).must_equal ["\e[1;1R"]
  end

  it 'keeps text of a sequence split between two chunks' do
    t = REPL::Terminal.new
    t.write "ab\e[1"
    t.write 'Gz'
    _(t.to_s).must_equal 'zb'
  end
end
