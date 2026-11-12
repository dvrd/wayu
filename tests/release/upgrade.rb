#!/usr/bin/env ruby
# Previous published binary -> candidate, including the first new shell.
# All keys use a file backend inside a temporary HOME; no real keychain.
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'shellwords'

previous = File.expand_path(ENV.fetch('WAYU_PREVIOUS_BIN'))
candidate = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
[previous, candidate].each { |p| abort("Not executable: #{p}") unless File.executable?(p) }
shells = %w[zsh bash fish].map do |name|
  exe = ENV.fetch('PATH').split(':').map { |d| File.join(d, name) }.find { |p| File.executable?(p) }
  abort("Required shell missing: #{name}") unless exe
  [name, exe]
end
def run!(env, *args, input: '')
  out, err, st = Open3.capture3(env, *args, stdin_data: input, unsetenv_others: true)
  raise "#{args.inspect}: exit #{st.exitstatus}\n#{out}\n#{err}" unless st.success?
  out
end
puts "Previous: #{Open3.capture2(previous, '--version').first.strip}"
puts "Candidate: #{Open3.capture2(candidate, '--version').first.strip}"
root = Dir.mktmpdir('wayu-upgrade-')
begin
  shells.each do |shell, exe|
    home = File.join(root, shell)
    cfg = File.join(home, '.config/wayu')
    data = File.join(home, '.local/share/wayu')
    FileUtils.mkdir_p([cfg, "#{home}/bin", "#{home}/tmp", "#{home}/tools"])
    File.write("#{cfg}/wayu.toml", "[secrets]\nbackend = \"file\"\n")
    stable = "#{home}/bin/wayu"
    FileUtils.cp(previous, stable)
    FileUtils.chmod(0o755, stable)
    env = { 'HOME' => home, 'PATH' => "#{home}/bin:#{ENV.fetch('PATH')}",
            'SHELL' => exe, 'NO_COLOR' => '1', 'TERM' => 'xterm-256color',
            'TMPDIR' => "#{home}/tmp/", 'XDG_RUNTIME_DIR' => "#{home}/tmp",
            'LANG' => 'C.UTF-8', 'USER' => 'wayu-upgrade-test' }
    run!(env, stable, 'init', '--shell', shell)
    rc = shell == 'fish' ? "#{home}/.config/fish/config.fish" : "#{home}/.#{shell}rc"
    FileUtils.mkdir_p(File.dirname(rc))
    File.write(rc, "source #{Shellwords.escape("#{data}/init.#{shell}")}\n")
    File.write("#{home}/tools/upgrade-tool", "#!/bin/sh\necho path-ok\n")
    FileUtils.chmod(0o755, "#{home}/tools/upgrade-tool")
    run!(env, stable, 'path', 'add', "#{home}/tools")
    run!(env, stable, 'alias', 'add', 'up_alias', 'echo alias-ok')
    run!(env, stable, 'const', 'add', 'UP_PLAIN', 'plain-ok')
    run!(env, stable, 'const', 'add', 'UP_SECRET', '--secret', input: "upgrade-fixture-secret\n")
    run!(env, stable, 'const', 'add', 'UP_RUN', '--run-only', input: "upgrade-run-fixture\n")
    # Force the first candidate shell to decrypt again, using the old core.
    run!(env, stable, 'secrets', 'lock')
    FileUtils.cp(candidate, "#{home}/bin/.wayu-next")
    File.rename("#{home}/bin/.wayu-next", stable)
    init = Shellwords.escape("#{data}/init.#{shell}")
    probe = "source #{init}; printf 'plain=%s secret=%s\\n' \"$UP_PLAIN\" \"$UP_SECRET\"; upgrade-tool; "
    probe += shell == 'fish' ? 'functions -q up_alias; and echo alias-ok' : 'alias up_alias'
    flags = shell == 'fish' ? ['--no-config', '-i', '-c'] : ['-f', '-i', '-c']
    flags = ['--noprofile', '--norc', '-i', '-c'] if shell == 'bash'
    out = run!(env, exe, *flags, probe)
    raise "#{shell}: first candidate shell lost state: #{out}" unless
      out.include?('plain=plain-ok secret=upgrade-fixture-secret') && out.include?('path-ok') && out.include?('alias-ok')
    raise 'secret changed' unless run!(env, stable, 'const', 'get', 'UP_SECRET').strip == 'upgrade-fixture-secret'
    run!(env, stable, 'secrets', 'run', 'UP_RUN', '--', '/bin/sh', '-c', 'test "$UP_RUN" = upgrade-run-fixture')
    run!(env, stable, 'build')
    run!(env, stable, 'doctor', '--json')
    run!(env, stable, 'secrets', 'rekey')
    raise 'secret lost after rekey' unless run!(env, stable, 'const', 'get', 'UP_SECRET').strip == 'upgrade-fixture-secret'
    run!(env, stable, 'doctor', '--json')
    puts "PASS #{shell}: first shell, PATH, alias, plain/secret/run-only constants, build, doctor, rekey"
  end
ensure
  FileUtils.rm_rf(root)
end
