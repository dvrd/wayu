#!/usr/bin/env ruby
require 'open3'
require 'tmpdir'
require 'optparse'

seed = 17
OptionParser.new { |p| p.on('--seed N', Integer) { |n| seed = n } }.parse!
random = Random.new(seed)
binary = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
Dir.mktmpdir('wayu-native-oracle') do |home|
  env = { 'HOME' => home, 'WAYU_CONFIG_DIR' => "#{home}/config", 'WAYU_DATA_DIR' => "#{home}/data",
          'PATH' => '/usr/bin:/bin', 'SHELL' => '/bin/bash', 'LC_ALL' => 'C' }
  examples = []
  10.times do
    a, b, c = Array.new(3) { random.rand(-20..20) }
    examples << ["echo $((#{a} + #{b} * #{c}))", 0, "#{a+b*c}\n", nil]
    n = random.rand(1..125)
    examples << ["sh -c 'exit #{n}' || echo recovered", 0, "recovered\n", nil]
    examples << ["sh -c 'exit #{n}' | true; echo skipped", n, '', n]
  end
  [0, 1, 127, 128, 141, 255].each do |status|
    examples << ["sh -c 'exit #{status}' | true", status, '', status.zero? ? nil : status]
  end
  examples << ['yes | head -n 1 > /dev/null', 0, '', nil]
  examples.each do |source, code, stdout, diagnostic|
    script = File.join(home,'trace.wy')
    File.write(script, source + "\n")
    [['-c', source], [script]].each do |args|
      out, err, st = Open3.capture3(env, binary, *args, unsetenv_others: true)
      expected_err = diagnostic ? err.include?("status #{diagnostic}") : err.empty?
      unless st.exitstatus == code && out == stdout && expected_err
        raise "seed #{seed}, minimal expression #{source.inspect}, argv #{args.inspect}: #{[st.exitstatus,out,err].inspect}"
      end
    end
  end
end
