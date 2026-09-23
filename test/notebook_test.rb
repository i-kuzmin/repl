# frozen_string_literal: true
#
# The preprocessing/crafting rules of `repl notebook`, as described in the
# "Special functions: notebook" section of README.md, exercised on the
# parser alone: what reaches the kernel, and what is written back once the
# answers are known.
require 'minitest/autorun'

load File.expand_path('../repl', __dir__)

# Parses `input`, answers every command with the next value of `answers` and
# returns the crafted buffer.
def craft(input, *answers)
  script = REPL::Notebook.parse(input)
  script.commands.reject(&:blank?).each_with_index do |command, i|
    command.output = answers[i]
  end
  script.render
end

def commands_of(input)
  REPL::Notebook.parse(input).commands.map(&:code)
end

describe REPL::Notebook do
  describe 'markdown fences' do
    it 'hides an opening fence, and anything before it, from the kernel' do
      _(commands_of("data before\n```bash\nrepl_cmd\n")).must_equal ["repl_cmd\n"]
    end

    it 'hides a closing fence, and anything after it, from the kernel' do
      _(commands_of("repl_cmd\n```\n")).must_equal ["repl_cmd\n"]
    end

    it 'echoes the fences back around the crafted answer' do
      _(craft("```bash\nrepl_cmd\n```\n", "answer\n"))
        .must_equal "```bash\nrepl_cmd\n#=>\n# answer\n#==\n```\n"
    end
  end

  describe 'output blocks' do
    it 'replaces a stale answer with a fresh one' do
      _(craft("cmd\n#=>\n# stale\n#==\n", "fresh\n"))
        .must_equal "cmd\n#=>\n# fresh\n#==\n"
    end

    it 'fills an empty block' do
      _(craft("cmd\n#=>\n#==\n", "fresh\n"))
        .must_equal "cmd\n#=>\n# fresh\n#==\n"
    end

    it 'ends a block without a terminator at the first non comment line' do
      input = "cmd\n#=>\n# stale\nnext_cmd\n"
      _(commands_of(input)).must_equal ["cmd\n", "next_cmd\n"]
      _(craft(input, "one\n", "two\n"))
        .must_equal "cmd\n#=>\n# one\n#==\nnext_cmd\n#=>\n# two\n#==\n"
    end

    it 'prepends every answer line with a comment marker' do
      _(craft("cmd\n#=>\n#==\n", "one\ntwo\n"))
        .must_equal "cmd\n#=>\n# one\n# two\n#==\n"
    end

    it 'leaves the block empty when the command answered nothing' do
      _(craft("cmd\n#=>\n# stale\n#==\n", ''))
        .must_equal "cmd\n#=>\n#==\n"
    end

    it 'keeps the indentation of the marker' do
      _(craft("  cmd\n  #=>\n  #==\n", "answer\n"))
        .must_equal "  cmd\n  #=>\n  # answer\n  #==\n"
    end
  end

  # The server keeps every answer under the id of the request that produced
  # it; the id is stamped into the terminator so that `show ID` can hand the
  # whole of it out again.
  describe 'answer ids' do
    def craft_with_id(input, answer, id)
      script = REPL::Notebook.parse(input)
      command = script.commands.reject(&:blank?).first
      command.output = answer
      command.id = id
      script.render
    end

    it 'stamps the id of the answer into the terminator' do
      _(craft_with_id("cmd\n#=>\n#==\n", "fresh\n", 45))
        .must_equal "cmd\n#=>\n# fresh\n#==[45]\n"
    end

    it 'replaces the id of a stale answer' do
      _(craft_with_id("cmd\n#=>\n# stale\n#==[7]\n", "fresh\n", 45))
        .must_equal "cmd\n#=>\n# fresh\n#==[45]\n"
    end

    it 'keeps a stamped terminator out of the kernel' do
      _(commands_of("cmd\n#=>\n# stale\n#==[7]\nnext_cmd\n#=>\n#==\n"))
        .must_equal ["cmd\n", "next_cmd\n"]
    end

    it 'keeps the indentation of a stamped terminator' do
      _(craft_with_id("  cmd\n  #=>\n  #==\n", "answer\n", 3))
        .must_equal "  cmd\n  #=>\n  # answer\n  #==[3]\n"
    end

    it 'leaves the terminator alone when the block was not run' do
      _(craft("cmd\n#=>\n# stale\n#==[7]\n", "fresh\n"))
        .must_equal "cmd\n#=>\n# fresh\n#==[7]\n"
    end
  end

  describe 'splitting' do
    it 'splits the buffer on every marker' do
      _(commands_of("a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n"))
        .must_equal ["a = [1,2,3]\n", "a[1]\n"]
    end

    it 'crafts the README example' do
      _(craft("a = [1,2,3]\n#=>\n# stale\n#==\na[1]\n#=>\n#==\n",
              "[1, 2, 3]\n", "2\n"))
        .must_equal "a = [1,2,3]\n#=>\n# [1, 2, 3]\n#==\na[1]\n#=>\n# 2\n#==\n"
    end

    it 'sends a multi line command as one block' do
      _(commands_of("if true; then\n  echo hi\nfi\n#=>\n#==\n"))
        .must_equal ["if true; then\n  echo hi\nfi\n"]
    end

    it 'shows one answer at the end when there is no marker at all' do
      input = "a = 1\na + 1\n"
      _(commands_of(input)).must_equal ["a = 1\na + 1\n"]
      _(craft(input, "2\n")).must_equal "a = 1\na + 1\n#=>\n# 2\n#==\n"
    end

    it 'gives the code left after the last block a block of its own' do
      _(craft("a\n#=>\n#==\nb\n", "one\n", "two\n"))
        .must_equal "a\n#=>\n# one\n#==\nb\n#=>\n# two\n#==\n"
    end

    it 'keeps blank lines that trail the last block out of the kernel' do
      input = "a\n#=>\n#==\n\n"
      _(commands_of(input)).must_equal ["a\n"]
      _(craft(input, "one\n")).must_equal "a\n#=>\n# one\n#==\n\n"
    end

    it 'clears a block whose command is blank without asking the kernel' do
      script = REPL::Notebook.parse("\n#=>\n# stale\n#==\n")
      _(script.commands.map(&:blank?)).must_equal [true]
      _(script.render).must_equal "\n#=>\n#==\n"
    end
  end
end
