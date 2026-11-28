#!/usr/bin/env ruby
# Publication contract: a saved change whose required host runtime file cannot
# be refreshed keeps the change, exits 74, names the shell and the path on
# stderr, and is repaired by `wayu build`. A failed store write saves nothing
# and never says "saved". Groups: entry (store edits, build, init), config
# (config tools, doctor, watcher) and repair (restore, secrets, scripts).
require_relative 'test_helper'
require 'optparse'
require 'digest'

class PublicationTest
  include WayuTestHelper

  LOADER = "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.bash\"\n"
  SECRET = 'publication-secret-value'

  def initialize
    setup_test_env
    build_project
  end

  def cli(*args, code: 0, env: {})
    base = { 'HOME' => @tmp_home, 'SHELL' => '/bin/bash', 'NO_COLOR' => '1', 'EDITOR' => 'true' }
    out, err, status = Open3.capture3(base.merge(env), @wayu_bin, *args)
    raise "#{args.inspect}: expected #{code}, got #{status.exitstatus}\n#{out}\n#{err}" unless status.exitstatus == code
    [out, err]
  end

  def data(file)
    File.join(@data_dir, file)
  end

  # Secrets stay in the test home: the default macOS backend is the login keychain.
  def init_shells
    FileUtils.mkdir_p(@config_dir)
    File.write(File.join(@config_dir, 'wayu.toml'), "[secrets]\nbackend = \"file\"\n")
    %w[bash zsh].each { |shell| cli('init', '--shell', shell) }
  end

  # A directory where a runtime file belongs makes its atomic replacement fail.
  def block(file)
    FileUtils.rm_rf(data(file))
    FileUtils.mkdir_p(data(file))
    data(file)
  end

  def unblock(file)
    FileUtils.rm_rf(data(file)) if File.directory?(data(file))
  end

  def blocked(file)
    yield block(file)
  ensure
    unblock(file)
  end

  def saved_failure!(err, path, shell = 'bash')
    return if err.include?(path) && err.include?("#{shell} runtime file") && err.include?('changes saved') && err.include?('wayu build')
    raise "missing partial-save diagnostic for #{path}: #{err}"
  end

  def shell_output(shell, script)
    args = shell == 'bash' ? ['--noprofile', '--norc'] : ['-f']
    out, status = Open3.capture2e({ 'HOME' => @tmp_home }, shell, *args, '-c', "source \"$1\" && { #{script}\n}", shell, data("init.#{shell}"))
    raise "fresh #{shell}: #{out}" unless status.success?
    out
  end

  # Every regular file and link under the test home. Bytecode is compiled in the
  # background after a command returns, so it is not part of a command's writes.
  def snapshot
    Dir.glob(File.join(@tmp_home, '**', '*'), File::FNM_DOTMATCH).sort.each_with_object({}) do |path, files|
      next if path.end_with?('.zwc') || File.directory?(path)
      files[path] = File.symlink?(path) ? File.readlink(path) : Digest::SHA256.file(path).hexdigest
    end
  end

  def entry
    # Without host configuration the native shell and a store edit work, and
    # no host runtime file appears. An explicit build keeps its own status.
    cli('-c', 'echo native')
    out, = cli('alias', 'add', 'native_only', 'echo native')
    raise "native-only mutation: #{out}" unless out.include?('Alias added: native_only')
    raise 'a mutation without host configuration created a host runtime' unless Dir.glob(data('{init,core,path_sync}.*')).empty?
    _, err = cli('build', code: 78)
    raise "build without configuration: #{err}" unless err.include?('wayu init')

    init_shells
    raise 'init did not publish the earlier edit' unless shell_output('bash', 'alias native_only').include?('echo native')

    # A failed store write is a different outcome: nothing is saved, nothing says so.
    if Process.euid.zero?
      puts 'NOT RUN blocked store: permission denial cannot be tested as root'
    else
      store = File.binread(@entries_file)
      runtime = File.binread(data('core.bash'))
      target = File.join(@scratch, 'blocked-store')
      Dir.mkdir(target)
      File.chmod(0o500, @data_dir)
      begin
        [%w[alias add blocked_store true], %w[const add BLOCKED_STORE 1], ['path', 'add', target]].each do |args|
          _, err = cli(*args, code: 74)
          raise "#{args.inspect} reported a failed store write as saved: #{err}" if err.include?('saved') || !err.include?('entries.json')
        end
      ensure
        File.chmod(0o700, @data_dir)
      end
      raise 'a failed store write changed the store' unless File.binread(@entries_file) == store
      raise 'a failed store write changed the runtime' unless File.binread(data('core.bash')) == runtime
    end

    probe_dir = File.join(@scratch, 'publication-probe')
    Dir.mkdir(probe_dir)
    # A saved change runs its hooks once, also when the refresh then fails.
    hooks = File.join(@config_dir, 'hooks.conf')
    hook_log = File.join(@tmp_home, 'hook.log')
    File.write(hooks, <<~HOOKS)
      pre_alias_add = echo pre-alias {name} >> ~/hook.log
      post_alias_add = echo post-alias {name} >> ~/hook.log
      post_alias_remove = echo post-alias-remove {name} >> ~/hook.log
      post_constant_add = echo post-constant {name} >> ~/hook.log
      post_path_add = echo post-path >> ~/hook.log
    HOOKS
    hooked = "pre-alias publication_probe\npost-alias publication_probe\npost-constant PUBLICATION_VAR\npost-path\npost-alias-remove native_only\n"
    blocked('core.bash') do |core|
      out, err = cli('alias', 'add', 'publication_probe', 'printf ready', code: 74)
      saved_failure!(err, core)
      raise "unqualified success: #{out}" if out.include?('Alias added')
      raise 'missing stored alias' unless cli('alias', 'get', 'publication_probe').first.include?('printf ready')
      raise 'other shell was left stale' unless File.read(data('core.zsh')).include?('publication_probe')

      out, err = cli('build', code: 74)
      raise "build did not name the failed output: #{err}" unless err.include?(core) && err.include?('bash runtime file')
      raise "build reported the failed shell as generated: #{out}" if out.include?('core.bash')
      raise "build did not report the refreshed shell: #{out}" unless out.include?('core.zsh')
      _, err = cli('init', '--shell', 'bash', code: 74)
      raise "init did not name the failed output: #{err}" unless err.include?(core)

      saved_failure!(cli('const', 'add', 'PUBLICATION_VAR', 'persisted', code: 74).last, core)
      saved_failure!(cli('path', 'add', probe_dir, code: 74).last, core)
      saved_failure!(cli('alias', 'rm', 'native_only', code: 74).last, core)
      raise "hooks around saved changes: #{File.read(hook_log)}" unless File.read(hook_log) == hooked

      gone = File.join(@scratch, 'publication-gone')
      Dir.mkdir(gone)
      saved_failure!(cli('path', 'add', "gone=#{gone}", code: 74).last, core)
      Dir.rmdir(gone)
      saved_failure!(cli('path', 'clean', '--yes', code: 74).last, core)
      raise 'path clean did not save its removal' if store_map('paths').key?('gone')
      hooked += "post-path\n"

      # A dry run previews and leaves every file as it was, obstruction or not,
      # and runs no hook.
      before = snapshot
      out, = cli('alias', 'add', 'preview', 'true', '--dry-run')
      raise "dry run did not preview the change: #{out}" unless out.include?('preview')
      cli('const', 'rm', 'PUBLICATION_VAR', '--dry-run')
      cli('build', '--dry-run')
      raise 'a dry run changed the filesystem' unless snapshot == before
    end

    2.times { cli('build') }
    # The repair regenerates files. It does not run the hooks again.
    raise "a repair replayed hooks: #{File.read(hook_log)}" unless File.read(hook_log) == hooked
    File.unlink(hooks)
    seen = shell_output('bash', 'alias publication_probe; printf "var=%s\n" "$PUBLICATION_VAR"; printf "path=%s\n" "$PATH"; alias native_only 2>/dev/null || echo native_only-removed')
    unless seen.include?("printf ready") && seen.include?('var=persisted') && seen.include?(probe_dir) && seen.include?('native_only-removed')
      raise "fresh Bash after repair: #{seen}"
    end

    # A user-edited init is never rewritten, whether or not the rest publishes.
    init = data('init.bash')
    custom = File.read(init) + "\n# local edit\n"
    File.write(init, custom)
    _, err = cli('alias', 'add', 'after_custom', 'true')
    raise "missing local-edit notice: #{err}" unless err.include?('local edits')
    blocked('core.bash') { cli('build', code: 74) }
    cli('build')
    raise 'a customized init was rewritten' unless File.read(init) == custom
    raise 'a customized init stopped the runtime refresh' unless shell_output('bash', 'alias after_custom').include?('true')

    # Stale zsh bytecode that cannot be removed would shadow the new text: the
    # refresh fails for zsh and the diagnostic names the bytecode file.
    zwc = data('core.zsh.zwc')
    FileUtils.rm_rf(zwc)
    FileUtils.mkdir_p(File.join(zwc, 'keep'))
    _, err = cli('alias', 'add', 'bytecode_probe', 'true', code: 74)
    saved_failure!(err, data('core.zsh'), 'zsh')
    raise "bytecode obstruction not named: #{err}" unless err.include?(zwc)
    FileUtils.rm_rf(zwc)
    cli('build')
    raise 'zsh did not load the repaired runtime' unless shell_output('zsh', 'alias bytecode_probe').include?('true')

    # Bytecode is optional: without a compiler the loadable text is still published.
    empty = File.join(@scratch, 'no-tools')
    Dir.mkdir(empty)
    cli('alias', 'add', 'without_bytecode', 'true', env: { 'PATH' => empty })
    raise 'runtime text depends on the bytecode compiler' unless File.read(data('core.zsh')).include?('without_bytecode')
  end

  def appears?(file, text, pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return true if File.read(file).include?(text)
      raise "watcher exited: #{File.read(file)}" if Process.waitpid(pid, Process::WNOHANG)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
  end

  # The watcher's first poll only records the files, so an edit made before it
  # is not a change. Edit again until the watcher reports one.
  def edit_until(toml, file, text, pid)
    5.times do |attempt|
      File.open(toml, 'a') { |f| f.puts "# watched edit #{attempt}" }
      return if appears?(file, text, pid, 3)
    end
    raise "watcher did not print #{text.inspect}: #{File.read(file)}"
  end

  def watch
    out_file = File.join(@scratch, 'watch.out')
    err_file = File.join(@scratch, 'watch.err')
    toml = File.join(@config_dir, 'wayu.toml')
    core = block('core.bash')
    pid = Process.spawn({ 'HOME' => @tmp_home, 'SHELL' => '/bin/bash', 'NO_COLOR' => '1' }, @wayu_bin, 'watch',
                        in: File::NULL, out: out_file, err: err_file)
    begin
      raise "watcher did not start: #{File.read(err_file)}" unless appears?(out_file, 'Debounce', pid, 15)
      edit_until(toml, err_file, core, pid)
      raise 'the watcher reported a failed refresh as done' if File.read(out_file).include?('regenerated')
      unblock('core.bash')
      edit_until(toml, out_file, 'Shell init files regenerated', pid)
      raise 'the watcher stopped after a failed refresh' if Process.waitpid(pid, Process::WNOHANG)
    ensure
      begin
        Process.kill('TERM', pid)
        Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
      end
      unblock('core.bash')
    end
  end

  def config
    init_shells
    bashrc = File.join(@tmp_home, '.bashrc')
    missing = File.join(@scratch, 'gone')
    Dir.mkdir(missing)
    cli('path', 'add', missing)
    Dir.rmdir(missing)

    blocked('core.bash') do |core|
      _, err = cli('reload', 'regenerate', code: 74)
      raise "reload did not name the failed output: #{err}" unless err.include?(core)

      # Malformed plugin metadata stays a configuration error, and the output
      # failure that happened in the same run is still reported.
      plugins = data('plugins.json')
      previous = File.file?(plugins) ? File.binread(plugins) : nil
      File.write(plugins, '{')
      [['build'], ['init', '--shell', 'bash']].each do |args|
        _, err = cli(*args, code: 78)
        raise "#{args.inspect} hid the concurrent output failure: #{err}" unless err.include?(core) && err.include?('plugins.json')
      end
      previous ? File.binwrite(plugins, previous) : File.unlink(plugins)

      saved_failure!(cli('config', 'edit', code: 74).last, core)
      saved_failure!(cli('completions', 'fpath', 'add', @scratch, code: 74).last, core)

      # A template saves every entry and refreshes once: one diagnostic, no
      # saved entry called skipped, no closing success line.
      out, err = cli('template', 'apply', 'developer', code: 74)
      saved_failure!(err, core)
      raise "template repeated or mislabeled the failure: #{err}" if err.include?('skipped') || err.scan('could not refresh').size != 1
      raise "template reported success: #{out}" if out.include?('template applied')
      raise 'template entries were not saved' unless store_map('aliases')['gs'] == 'git status'
      raise 'template dry run wrote' unless cli('template', 'apply', 'full', '--dry-run').first.include?('Nothing was written')

      File.write(bashrc, LOADER + "alias moved_by_optimize='true'\n")
      cli('optimize', '--dry-run')
      raise 'optimize dry run wrote' unless File.read(bashrc).include?('moved_by_optimize') && !store_map('aliases').key?('moved_by_optimize')
      saved_failure!(cli('optimize', '--yes', code: 74).last, core)
      raise 'optimize did not keep its completed move' unless store_map('aliases')['moved_by_optimize'] == 'true' && File.read(bashrc) == LOADER

      # doctor --fix keeps its aggregation: the fix is saved and listed as
      # needing manual action, and the exit status still follows the re-check.
      out, err, status = Open3.capture3({ 'HOME' => @tmp_home, 'SHELL' => '/bin/bash', 'NO_COLOR' => '1' }, @wayu_bin, 'doctor', '--fix', '--yes')
      _, _, recheck = Open3.capture3({ 'HOME' => @tmp_home, 'SHELL' => '/bin/bash', 'NO_COLOR' => '1' }, @wayu_bin, 'doctor')
      raise "doctor did not report the unfinished fix: #{out}\n#{err}" unless out.include?('Manual fixes needed') && out.include?('changes saved') && err.include?(core)
      raise 'doctor --fix did not save its fix' if store_map('paths').value?(missing)
      raise "doctor --fix exit #{status.exitstatus} differs from its re-check #{recheck.exitstatus}" unless status.exitstatus == recheck.exitstatus
    end

    # Repair, then a new change publishes normally.
    cli('reload', 'regenerate')
    cli('alias', 'add', 'after_repair', 'true')
    seen = shell_output('bash', 'alias gs; alias moved_by_optimize; alias after_repair')
    raise "fresh Bash after repair: #{seen}" unless seen.include?('git status') && seen.include?('moved_by_optimize') && seen.include?('after_repair')

    # Each required artifact fails the build on its own and is named.
    cli('export', '--shell', 'bash')
    { 'path_sync.bash' => 'bash', 'turbo.bash' => 'bash', 'init.bash' => 'bash', 'plugins.bash' => 'bash',
      'plugins/config.zsh' => 'zsh' }.each do |file, shell|
      blocked(file) do |path|
        _, err = cli('build', code: 74)
        raise "missing failed artifact #{file}: #{err}" unless err.include?(path) && err.include?("#{shell} runtime file")
      end
      cli('init', '--shell', 'bash') if file == 'init.bash'
      cli('build')
    end

    watch
    raise 'the watcher did not publish after the repair' unless File.file?(data('core.bash'))
  end

  def repair
    init_shells
    blocked('core.bash') do |core|
      # Restore: the restored store is kept.
      cli('alias', 'add', 'repair_probe', 'true', code: 74)
      cli('alias', 'add', 'repair_probe', 'false', code: 74)
      saved_failure!(cli('backup', 'restore', 'alias', '--yes', code: 74).last, core)
      raise 'restore did not keep the restored store' unless cli('alias', 'get', 'repair_probe').first.strip == 'true'

      # Secrets: ciphertext, marker and key are kept; the value is never printed
      # and never handed to a hook.
      File.write(File.join(@config_dir, 'hooks.conf'), "post_constant_add = echo post-constant {name} value={value}. >> ~/hook.log\n")
      out, err = cli('const', 'add', 'PUBLICATION_SECRET', SECRET, '--secret', code: 74)
      saved_failure!(err, core)
      raise 'a diagnostic printed the secret value' if (out + err).include?(SECRET)
      hook_log = File.read(File.join(@tmp_home, 'hook.log'))
      raise "secret hook: #{hook_log}" unless hook_log == "post-constant PUBLICATION_SECRET value=.\n"
      File.unlink(File.join(@config_dir, 'hooks.conf'))
      raise 'the secret was not saved' unless cli('const', 'get', 'PUBLICATION_SECRET').first.strip == SECRET
      marker = read_entries['env'].find { |e| e['name'] == 'PUBLICATION_SECRET' }
      raise "missing secret marker: #{marker.inspect}" unless marker && marker['secret'] == true && marker['value'].to_s.empty?
      raise 'the store holds the secret in plaintext' if File.read(@entries_file).include?(SECRET) || File.read(data('secrets.json')).include?(SECRET)
      key_file = File.join(@config_dir, 'secret.key')
      key = File.binread(key_file)

      # Scripts: the created script and its bin entry are kept.
      out, err = cli('script', 'new', 'publication_script', '--lang', 'sh', code: 74)
      saved_failure!(err, core)
      raise "script was not kept: #{out}" unless File.file?(data('scripts/publication_script.sh')) && File.symlink?(data('bin/publication_script'))

      out, err = cli('const', 'rm', 'PUBLICATION_SECRET', code: 74)
      saved_failure!(err, core)
      raise 'a diagnostic printed the secret value' if (out + err).include?(SECRET)
      raise 'the removed secret is still stored' if read_entries['env'].any? { |e| e['name'] == 'PUBLICATION_SECRET' }
      raise 'the key changed during a failed refresh' unless File.binread(key_file) == key
      cli('const', 'add', 'PUBLICATION_SECRET', SECRET, '--secret', code: 74)
    end

    # A fresh process repairs the runtime from the saved state, without redoing the edits.
    store = File.binread(@entries_file)
    2.times { cli('build') }
    raise 'the repair changed the store' unless File.binread(@entries_file) == store
    runtime = File.read(data('core.bash'))
    raise 'the runtime holds the secret in plaintext' if runtime.include?(SECRET)
    seen = shell_output('bash', 'alias repair_probe; command -v publication_script')
    raise "fresh Bash after repair: #{seen}" unless seen.include?("repair_probe='true'") && seen.include?(data('bin/publication_script'))
    raise 'the secret is unreadable after the repair' unless cli('const', 'get', 'PUBLICATION_SECRET').first.strip == SECRET

    blocked('core.bash') do |core|
      saved_failure!(cli('script', 'remove', 'publication_script', '--yes', code: 74).last, core)
      raise 'the script removal was not kept' if File.exist?(data('scripts/publication_script.sh')) || File.symlink?(data('bin/publication_script'))
    end
    cli('build')
  end

  def run(group)
    send(group)
    puts "PASS publication: #{group}"
  ensure
    teardown_test_env
  end
end

group = 'all'
OptionParser.new { |p| p.on('--group GROUP', %w[all entry config repair]) { |v| group = v } }.parse!
(group == 'all' ? %w[entry config repair] : [group]).each { |name| PublicationTest.new.run(name) }
