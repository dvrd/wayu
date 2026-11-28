#!/usr/bin/env ruby
# An independent model of the native shell's documented arithmetic and failure
# rules (docs/cli.md, "Native shell") predicts exit status, stdout and stderr
# for generated commands. Each command runs as a command string and as a
# script file. A disagreement is reduced to the smallest command that still
# disagrees and printed with its seed: rerun with --seed N.
require 'open3'
require 'tmpdir'
require 'optparse'

INT_MIN = -(2**63)
INT_MAX = 2**63 - 1
ArithmeticFailure = Class.new(StandardError)

# name => [assigned text (nil: never assigned), the value the rules give it]
VARIABLES = {
  'a' => ['12', 12], 'b' => ['-5', -5], 'e' => ['', 0], 'u' => [nil, 0],
  'm' => [INT_MAX.to_s, INT_MAX], 'n' => [INT_MIN.to_s, INT_MIN]
}.freeze
ASSIGNMENTS = VARIABLES.map { |name, (text, _)| text && "#{name}=#{text}" }.compact.join('; ').freeze
LITERALS = [0, 1, 2, 3, 5, 7, 10, 255, 4096, 2**31 - 1, 2**32, 3_037_000_499, 3_037_000_500, 2**62, INT_MAX].freeze
PRECEDENCE = { '+' => 1, '-' => 1, '*' => 2, '/' => 2, '%' => 2 }.freeze
STATUSES = [0, 0, 0, 1, 2, 3, 42, 125, 141, 200, 255].freeze

# Expressions: [:lit, n], [:var, name, dollar], [:pos, x], [:neg, x],
# [:bin, operator, left, right, redundant parentheses].
def expression(rng, depth)
  if depth.zero? || rng.rand(4).zero?
    return [:var, VARIABLES.keys.sample(random: rng), rng.rand(2).zero?] if rng.rand(3).zero?
    return [:lit, LITERALS.sample(random: rng)]
  end
  return [rng.rand(4).zero? ? :pos : :neg, expression(rng, depth - 1)] if rng.rand(5).zero?
  [:bin, PRECEDENCE.keys.sample(random: rng), expression(rng, depth - 1), expression(rng, depth - 1), rng.rand(6).zero?]
end

def checked(value)
  raise ArithmeticFailure unless value.between?(INT_MIN, INT_MAX)
  value
end

# Signed 64-bit integers. Unset and empty variables are zero. Division
# truncates toward zero. Division by zero and overflow are errors.
def evaluate(node)
  case node[0]
  when :lit then node[1]
  when :var then VARIABLES.fetch(node[1])[1]
  when :pos then evaluate(node[1])
  when :neg then checked(-evaluate(node[1]))
  else
    left = evaluate(node[2])
    right = evaluate(node[3])
    case node[1]
    when '+' then checked(left + right)
    when '-' then checked(left - right)
    when '*' then checked(left * right)
    else
      raise ArithmeticFailure if right.zero?
      quotient = left.abs / right.abs
      quotient = -quotient if (left < 0) ^ (right < 0)
      node[1] == '/' ? checked(quotient) : left - right * quotient
    end
  end
end

# Only the parentheses precedence and left association require, plus the
# redundant ones the generator asked for.
def render(node, parent = 0, right_side = false)
  case node[0]
  when :lit then node[1].to_s
  when :var then node[2] ? "$#{node[1]}" : node[1]
  when :pos, :neg
    operand = render(node[1], 3)
    operand = "(#{operand})" if %i[pos neg].include?(node[1][0])
    (node[0] == :neg ? '-' : '+') + operand
  else
    level = PRECEDENCE.fetch(node[1])
    text = "#{render(node[2], level)} #{node[1]} #{render(node[3], level, true)}"
    level < parent || (level == parent && right_side) || node[4] ? "(#{text})" : text
  end
end

def operands(node)
  case node[0]
  when :pos, :neg then [node[1]]
  when :bin then [node[2], node[3]]
  else []
  end
end

# [source, [status, stdout, stderr]]: stderr nil is empty, :any is not empty,
# a number is a diagnostic naming that status.
def arithmetic_cases(node)
  text = render(node)
  value = begin
    evaluate(node)
  rescue ArithmeticFailure
    nil
  end
  plain = value ? [0, "#{value}\n", nil] : [:nonzero, '', :any]
  [["#{ASSIGNMENTS}; echo $((#{text}))", plain],
   ["#{ASSIGNMENTS}; echo $((#{text})) || echo recovered", [0, value ? "#{value}\n" : "recovered\n", nil]]]
end

# Statements: [source, stdout, status, stops when the status is nonzero].
# `if`, `||`, the left side of `&&` and a loop condition test a status; any
# other nonzero status stops the script. A pipeline reports its rightmost
# failing stage. A failed substitution stops its command before it runs.
def statement(rng, index)
  n = STATUSES.sample(random: rng)
  child = "sh -c 'exit #{n}'"
  case rng.rand(8)
  when 0 then [child, '', n, true]
  when 1 then ["#{child} || echo r#{index}", n.zero? ? '' : "r#{index}\n", 0, false]
  when 2 then ["#{child} && echo y#{index}", n.zero? ? "y#{index}\n" : '', n, false]
  when 3 then ["if #{child}; then echo t#{index}; else echo f#{index}; fi", n.zero? ? "t#{index}\n" : "f#{index}\n", 0, false]
  when 4 then ["echo w#{index}", "w#{index}\n", 0, false]
  when 5
    last = STATUSES.sample(random: rng)
    ["#{child} | sh -c 'exit #{last}'", '', last.zero? ? n : last, true]
  when 6
    ["echo \"$(sh -c 'echo p#{index}; exit #{n}')\"", n.zero? ? "p#{index}\n" : '', n, n.nonzero? ? true : false]
  else ["while #{child}; do echo b#{index}; break; done", n.zero? ? "b#{index}\n" : '', 0, false]
  end
end

def program_case(statements)
  stdout = +''
  status = 0
  statements.each do |_, text, result, stops|
    stdout << text
    status = result
    return [statements.map(&:first).join('; '), [status, stdout, status]] if stops && status.nonzero?
  end
  [statements.map(&:first).join('; '), [status, stdout, nil]]
end

class Shell
  def initialize(binary, home)
    @binary = binary
    @script = File.join(home, 'trace.wy')
    @env = { 'HOME' => home, 'WAYU_CONFIG_DIR' => "#{home}/config", 'WAYU_DATA_DIR' => "#{home}/data",
             'PATH' => '/usr/bin:/bin', 'SHELL' => '/bin/bash', 'LC_ALL' => 'C' }
    %w[ASAN_OPTIONS LSAN_OPTIONS UBSAN_OPTIONS].each { |key| @env[key] = ENV[key] if ENV[key] }
    @runs = 0
  end

  attr_reader :runs

  # nil when both invocations agree with the prediction, else what differed.
  def mismatch(source, expected)
    status, stdout, stderr = expected
    File.write(@script, source + "\n")
    [['-c', source], [@script]].each do |args|
      @runs += 1
      out, err, result = Open3.capture3(@env, @binary, *args, unsetenv_others: true)
      code = result.exitstatus
      status_ok = status == :nonzero ? (code && code.nonzero?) : code == status
      stderr_ok = case stderr
                  when nil then err.empty?
                  when :any then !err.empty?
                  else err.include?("status #{stderr}")
                  end
      next if status_ok && out == stdout && stderr_ok
      return "argv #{args.inspect} gave status #{code.inspect}, stdout #{out.inspect}, stderr #{err.inspect}; " \
             "the model expects status #{status.inspect}, stdout #{stdout.inspect}, stderr #{stderr.inspect}"
    end
    nil
  end

  def first_mismatch(cases)
    cases.each do |source, expected|
      detail = mismatch(source, expected)
      return [source, detail] if detail
    end
    nil
  end
end

seed = 17
OptionParser.new { |p| p.on('--seed N', Integer) { |n| seed = n } }.parse!
rng = Random.new(seed)
binary = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
Dir.mktmpdir('wayu-native-oracle') do |home|
  shell = Shell.new(binary, home)
  report = lambda do |source, detail|
    raise "seed #{seed}, reduced command #{source.inspect}: #{detail}"
  end

  kinds = Hash.new(0)
  40.times do
    node = expression(rng, 3)
    kinds[arithmetic_cases(node)[0][1][0] == 0 ? :value : :error] += 1
    next unless shell.first_mismatch(arithmetic_cases(node))
    loop do
      smaller = operands(node).find { |operand| shell.first_mismatch(arithmetic_cases(operand)) }
      break unless smaller
      node = smaller
    end
    report.call(*shell.first_mismatch(arithmetic_cases(node)))
  end
  raise "seed #{seed} did not generate both values and errors: #{kinds.inspect}" unless kinds[:value] > 0 && kinds[:error] > 0

  30.times do
    statements = Array.new(rng.rand(1..4)) { |index| statement(rng, index) }
    next unless shell.mismatch(*program_case(statements))
    loop do
      index = statements.size > 1 && statements.each_index.find do |i|
        shell.mismatch(*program_case(statements[0...i] + statements[i + 1..-1]))
      end
      break unless index
      statements = statements[0...index] + statements[index + 1..-1]
    end
    source, expected = program_case(statements)
    report.call(source, shell.mismatch(source, expected))
  end

  # A stage ended by SIGPIPE because its reader finished is not a failure. A
  # program that exits 141 on purpose is, and so is a last stage killed by the
  # signal.
  [["sh -c 'kill -PIPE $$' | true", [0, '', nil]],
   ['yes | head -n 1', [0, "y\n", nil]],
   ["sh -c 'exit 141' | true", [141, '', 141]],
   ["sh -c 'exit 141' | head -n 1", [141, '', 141]],
   ["true | sh -c 'kill -PIPE $$'", [141, '', 141]],
   ["sh -c 'exit 141' || echo recovered", [0, "recovered\n", nil]]].each do |source, expected|
    detail = shell.mismatch(source, expected)
    report.call(source, detail) if detail
  end

  puts "PASS native model: seed #{seed}, #{shell.runs} runs, arithmetic #{kinds.inspect}"
end
