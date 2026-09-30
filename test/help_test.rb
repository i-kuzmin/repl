# frozen_string_literal: true
#
# General help lists commands and general options; command help lists the
# options of that command.
require 'minitest/autorun'
require 'stringio'

load File.expand_path('../repl', __dir__)

describe 'help' do
  def run_cli(*argv)
    out, err = StringIO.new, StringIO.new
    status = REPL::CommandLineInterface.new(out: out, err: err).invoke(argv)
    [out.string, err.string, status]
  end

  it 'general help lists every command and the general options' do
    %w[-h --help help].each do |flag|
      out, _err, status = run_cli(flag)
      _(status).must_equal 0
      REPL::CommandLineInterface::HELP.each_key do |command|
        _(out).must_match(/^  #{command}\s/)
      end
      _(out).must_include '--socket PATH|HASH'
      _(out).must_include 'REPL_SOCKET'
      _(out).wont_include '--no-header'
    end
  end

  it 'command help lists the options of that command only' do
    [%w[help ls], %w[ls -h], %w[ls -o name --help]].each do |argv|
      out, _err, status = run_cli(*argv)
      _(status).must_equal 0
      _(out).must_match(/\AUsage: repl ls/)
      _(out).must_include '--no-header'
      _(out).wont_include '--prompt'
    end
  end

  it 'kernel help lists the kernel options' do
    out, _err, status = run_cli('kernel', '-h')
    _(status).must_equal 0
    _(out).must_include '--prompt REGEX'
    _(out).must_include '--[no-]caching'
  end

  it 'get lists every key, set only the settable ones' do
    get, = run_cli('help', 'get')
    set, = run_cli('help', 'set')
    REPL::Server::KEYS.each { |key| _(get).must_match(/^  #{key}\s/) }
    _(set).wont_match(/^  cmd\s/)
    _(set).must_match(/^  name\s/)
  end

  it 'resolves aliases' do
    out, = run_cli('help', 'int')
    _(out).must_match(/\AUsage: repl .*interrupt/)
    out, = run_cli('ps', '-h')
    _(out).must_match(/\AUsage: repl ls/)
  end

  it 'fails on an unknown command' do
    _out, err, status = run_cli('help', 'bogus')
    _(status).wont_equal 0
    _(err).must_match(/unknown command 'bogus'/)
  end
end
