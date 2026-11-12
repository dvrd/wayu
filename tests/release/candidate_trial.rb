#!/usr/bin/env ruby
# Automated repeated-session trial, not a substitute for multi-day human use.
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'shellwords'
require 'digest'
require 'json'
require 'time'

binary = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
rounds = Integer(ENV.fetch('WAYU_TRIAL_ROUNDS', '20'))
abort 'Trial rounds must be between 2 and 100' unless (2..100).cover?(rounds)
abort "Candidate is not executable: #{binary}" unless File.executable?(binary)
binary_hash = Digest::SHA256.file(binary).hexdigest
results = []

def trial_run!(env, *args, input: '')
  out, err, status = Open3.capture3(env, *args, stdin_data: input, unsetenv_others: true)
  raise "#{args.first(3).inspect}: #{status}\n#{err}" unless status.success?
  out
end

%w[zsh bash fish].each do |shell|
  exe = ENV.fetch('PATH').split(':').map { |d| File.join(d, shell) }.find { |p| File.executable?(p) }
  abort "Required trial shell missing: #{shell}" unless exe
  Dir.mktmpdir("wayu candidate #{shell} ") do |home|
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    FileUtils.mkdir_p([cfg, "#{home}/bin", "#{home}/tools", "#{home}/run", "#{home}/tmp"])
    File.chmod(0700, "#{home}/run")
    File.write("#{cfg}/wayu.toml", "[secrets]\nbackend = \"file\"\n")
    candidate = "#{home}/bin/wayu"
    FileUtils.cp(binary, candidate)
    File.chmod(0755, candidate)
    env = { 'HOME' => home, 'PATH' => "#{home}/bin:#{ENV.fetch('PATH')}", 'SHELL' => exe,
            'NO_COLOR' => '1', 'TERM' => 'xterm-256color', 'TMPDIR' => "#{home}/tmp/",
            'XDG_RUNTIME_DIR' => "#{home}/run", 'LANG' => 'C.UTF-8', 'USER' => 'wayu-candidate-trial', 'TRIAL_REF' => 'expanded' }
    trial_run!(env, candidate, 'init', '--shell', shell)
    rc = shell == 'fish' ? "#{home}/.config/fish/config.fish" : "#{home}/.#{shell}rc"
    FileUtils.mkdir_p(File.dirname(rc))
    File.write(rc, "source #{Shellwords.escape("#{data}/init.#{shell}")}\n")
    File.write("#{home}/tools/trial-tool", "#!/bin/sh\necho PATH_OK\n")
    File.chmod(0755, "#{home}/tools/trial-tool")
    trial_run!(env, candidate, 'path', 'add', "#{home}/tools", '--portable')
    trial_run!(env, candidate, 'completions', 'generate')
    trial_run!(env, candidate, 'const', 'add', 'TRIAL_SECRET', '--secret', input: "candidate-fixture-secret\n")
    trial_run!(env, candidate, 'const', 'add', 'TRIAL_RUN', '--run-only', input: "candidate-fixture-run\n")
    trial_run!(env, candidate, 'doctor', '--json')

    rounds.times do |n|
      value = "round-#{n} 日本 ${TRIAL_REF} $9 'quoted'"
      expanded_value = "round-#{n} 日本 expanded $9 'quoted'"
      trial_run!(env, candidate, 'const', 'add', 'TRIAL_STATE', value)
      trial_run!(env, candidate, 'alias', 'add', 'trial_alias', "echo ALIAS_#{n}_OK")
      trial_run!(env, candidate, 'secrets', 'lock')
      trial_run!(env, candidate, 'secrets', 'rekey') if n > 0 && n % 7 == 0
      trial_run!(env, candidate, 'build') if n % 4 == 0
      trial_run!(env, candidate, 'export', '--turbo')
      trial_run!(env, candidate, 'export', '--check')
      probe = "trial-tool; printf 'STATE=%s\\n' \"$TRIAL_STATE\"; trial_alias; "
      if shell == 'fish'
        probe += 'test "$TRIAL_SECRET" = candidate-fixture-secret; and echo SECRET_OK; '
        probe += 'test -z "$TRIAL_RUN"; and echo RUN_ONLY_OK'
        flags = ['-i', '-c']
      else
        probe += 'test "$TRIAL_SECRET" = candidate-fixture-secret && echo SECRET_OK; '
        probe += 'test -z "${TRIAL_RUN-}" && echo RUN_ONLY_OK'
        flags = ['-i', '-c']
      end
      out = trial_run!(env, exe, *flags, probe)
      expected = ['PATH_OK', "STATE=#{expanded_value}", "ALIAS_#{n}_OK", 'SECRET_OK', 'RUN_ONLY_OK']
      raise "#{shell} round #{n}: missing state markers: #{out}" unless expected.all? { |v| out.lines.map(&:chomp).include?(v) }
      trial_run!(env, candidate, 'secrets', 'run', 'TRIAL_RUN', '--', '/bin/sh', '-c',
                 'test "$TRIAL_RUN" = candidate-fixture-run')
      got = trial_run!(env, candidate, 'const', 'get', 'TRIAL_STATE')
      raise 'stored state changed' unless got.chomp == value
      trial_run!(env, candidate, 'doctor', '--json') if n % 5 == 0
    end
    %w[entries.json secrets.json].each do |name|
      path = "#{data}/#{name}"
      raise "unsafe mode: #{path}" unless File.stat(path).mode & 0o777 == 0o600
    end
    %W[#{data}/entries.json #{data}/secrets.json #{data}/core.#{shell}].each do |path|
      raise "fixture plaintext in persistent #{path}" if File.binread(path).include?('candidate-fixture-secret')
    end
    trial_run!(env, candidate, 'doctor', '--json')
    raise 'trial copy changed' unless Digest::SHA256.file(candidate).hexdigest == binary_hash
    results << { 'shell' => shell, 'executable' => exe, 'rounds' => rounds,
                 'home_with_spaces' => true, 'result' => 'PASS' }
    puts "PASS candidate trial: #{shell}, #{rounds} fresh sessions, PATH/alias/plain/secret/run-only, rekey, build, export, doctor"
  end
end
raise 'candidate binary changed during trial' unless Digest::SHA256.file(binary).hexdigest == binary_hash
report = { 'recorded_at_utc' => Time.now.utc.iso8601, 'candidate_sha256' => binary_hash,
           'version' => Open3.capture2(binary, '--version').first.strip,
           'rounds_per_shell' => rounds, 'results' => results,
           'limits' => 'Automated repeated sessions; no elapsed multi-day/human-use claim or independent cryptographic assessment.' }
checkout = File.expand_path('../..', __dir__)
commit, commit_status = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: checkout)
changes, changes_status = Open3.capture2('git', 'status', '--porcelain', '--untracked-files=no', chdir: checkout)
report['checkout_commit'] = commit.strip if commit_status.success?
report['checkout_dirty'] = !changes.empty? if changes_status.success?
report['source_note'] = 'Checkout metadata is contextual; the supplied binary is identified by its SHA-256. CI builds it in this checkout.'
if ENV['WAYU_TRIAL_REPORT']
  FileUtils.mkdir_p(File.dirname(ENV['WAYU_TRIAL_REPORT']))
  File.write(ENV['WAYU_TRIAL_REPORT'], JSON.pretty_generate(report) + "\n")
end
puts JSON.generate(report)
