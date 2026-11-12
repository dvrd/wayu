#!/usr/bin/env ruby
# Offline reconstruction under a different HOME, using real Git and shells.
require 'open3'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'digest'

class PluginRestoreTest
  BIN = File.expand_path(ENV.fetch('WAYU_BIN', '../../bin/wayu'), ENV['WAYU_BIN'] ? Dir.pwd : __dir__)

  def run
    @failed = 0
    @passed = 0
    unless ENV['WAYU_BIN']
      out, st = Open3.capture2e('./build_it', 'build', chdir: File.expand_path('../..', __dir__))
      raise out unless st.success?
    end
    root = Dir.mktmpdir('wayu-restore-')
    begin
      @root = root
      @gitconfig = "#{root}/gitconfig"
      File.write(@gitconfig, "[user]\nname = test\nemail = test@example.test\n[commit]\ngpgsign = false\n[tag]\ngpgsign = false\n")
      @repo = "#{root}/origin"
      git('init', '-q', '-b', 'main', @repo)
      %w[zsh bash fish].each do |shell|
        File.write("#{@repo}/portable.#{shell}", shell == 'fish' ? "set -gx RESTORE_PLUGIN old\n" : "export RESTORE_PLUGIN=old\n")
      end
      git('-C', @repo, 'add', '.')
      git('-C', @repo, 'commit', '-qm', 'old')
      @sha = git('-C', @repo, 'rev-parse', 'HEAD')
      @source = "#{root}/source-home"
      command(@source, 'init')
      command(@source, 'plugin', 'add', "file://#{@repo}@#{@sha}")
      @snapshot = JSON.parse(File.read(data(@source) + '/plugins.json'))
      @snapshot['plugins'][0]['priority'] = 42
      # Advance the remote: reconstruction must still select the recorded SHA.
      File.write("#{@repo}/new", 'new')
      git('-C', @repo, 'add', '.')
      git('-C', @repo, 'commit', '-qm', 'new')

      test_fresh_machine
      test_dry_run
      test_failure_rolls_back
      test_backup_failure_rolls_back
      test_existing_checkout
      test_destination_collision
      test_invalid_metadata
      test_unpinned_branch
      test_tag_without_commit
      test_empty_and_wrong_origin
      test_missing_add_reports_recovery
      test_arguments
    ensure
      FileUtils.rm_rf(root)
    end
    puts "Plugin restore: #{@passed} passed, #{@failed} failed"
    exit(@failed.zero? ? 0 : 1)
  end

  def env(home)
    { 'HOME' => home, 'WAYU_CONFIG_DIR' => "#{home}/cfg", 'WAYU_DATA_DIR' => data(home),
      'XDG_DATA_HOME' => nil, 'XDG_CONFIG_HOME' => nil, 'SHELL' => '/bin/zsh',
      'NO_COLOR' => '1', 'GIT_CONFIG_GLOBAL' => @gitconfig, 'GIT_CONFIG_NOSYSTEM' => '1',
      'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'WAYU_GIT_TIMEOUT' => '5' }
  end

  def data(home)
    "#{home}/data"
  end

  def git(*args)
    out, st = Open3.capture2e(env(@root), 'git', *args)
    raise "git failed: #{out}" unless st.success?
    out.strip
  end

  def command(home, *args)
    out, st = Open3.capture2e(env(home), BIN, *args, stdin_data: '')
    raise "#{args.inspect}: #{out}" unless st.success?
    out
  end

  def fixture(name, snapshot = @snapshot)
    home = "#{@root}/#{name}"
    command(home, 'init')
    File.write(data(home) + '/plugins.json', JSON.pretty_generate(snapshot))
    home
  end

  def config(home)
    JSON.parse(File.read(data(home) + '/plugins.json'))
  end
  def checkout(home)
    data(home) + '/plugins/origin'
  end

  def check(label, ok, detail = '')
    puts "#{ok ? 'PASS' : 'FAIL'} #{label} #{ok ? '' : detail}"
    ok ? @passed += 1 : @failed += 1
  end

  def test_fresh_machine
    home = fixture('fresh')
    FileUtils.mkdir_p([data(@source) + '/functions', data(@source) + '/scripts', @source + '/tool-bin'])
    command(@source, 'path', 'add', 'portable=$HOME/tool-bin', '--portable')
    command(@source, 'alias', 'add', 'portable_alias', 'echo alias-ok')
    command(@source, 'const', 'add', 'RESTORE_CONST', 'constant-ok')
    %w[zsh bash fish].each do |shell|
      File.write(data(@source) + "/functions/portable_fn.#{shell}", shell == 'fish' ? "function portable_fn; echo function-ok; end\n" : "portable_fn() { echo function-ok; }\n")
    end
    File.write(data(@source) + '/scripts/portable_script.sh', "#!/bin/sh\necho script-ok\n")
    %w[entries.json functions scripts].each { |f| FileUtils.cp_r(data(@source) + '/' + f, data(home)) }
    FileUtils.cp(@source + '/cfg/wayu.toml', home + '/cfg/wayu.toml')
    FileUtils.mkdir_p(home + '/tool-bin')
    File.write(home + '/tool-bin/portable_path', "#!/bin/sh\necho path-ok\n")
    File.chmod(0o755, home + '/tool-bin/portable_path')
    before = File.binread(data(home) + '/plugins.json')
    command(home, 'plugin', 'restore')
    p = config(home)['plugins'][0]
    backups = Dir.glob(data(home) + '/backup/plugins.json.backup.*')
    check('relocates, restores pinned SHA and settings, backs up imported metadata',
          p['installed_path'] == checkout(home) && p['priority'] == 42 && p['git']['pinned_ref'] == @sha &&
          git('-C', checkout(home), 'rev-parse', 'HEAD') == @sha && backups.any? { |b| File.binread(b) == before })
    %w[zsh bash fish].each do |shell|
      exe = ENV.fetch('PATH').split(':').map { |d| "#{d}/#{shell}" }.find { |f| File.executable?(f) }
      raise "#{shell} is required" unless exe
      command(home, 'init', '--shell', shell)
      command(home, 'build', '--shell', shell)
      script = "source '#{data(home)}/init.#{shell}'; echo $RESTORE_PLUGIN $RESTORE_CONST; portable_fn; portable_script; portable_path; eval portable_alias"
      args = shell == 'fish' ? ['--no-config', '-i', '-c', script] : ['-f', '-i', '-c', script]
      args = ['--norc', '--noprofile', '-i', '-c', script] if shell == 'bash'
      # Bash only expands aliases after parsing the command containing them.
      args[-1] = "shopt -s expand_aliases; #{script}" if shell == 'bash'
      out, st = Open3.capture2e(env(home), exe, *args)
      check("fresh #{shell} restores plugin, constants, functions, scripts and aliases", st.success? &&
            out.include?('old constant-ok') && %w[function-ok script-ok alias-ok path-ok].all? { |x| out.include?(x) }, out)
    end
    command(home, 'doctor', '--json')
  end

  def test_dry_run
    home = fixture('dry')
    before = File.binread(data(home) + '/plugins.json')
    files = durable_snapshot(home)
    # Reproduce init's cache arriving after the baseline deterministically.
    File.write(data(home) + '/async-fixture.zwc', 'bytecode fixture')
    out = command(home, 'plugin', 'restore', '--dry-run')
    check('dry-run preserves files and never clones', out.include?('DRY RUN') &&
          File.binread(data(home) + '/plugins.json') == before && !File.exist?(checkout(home)) &&
          files == durable_snapshot(home))
  end

  # init compiles zsh bytecode asynchronously. A cache appearing during a
  # preview is not a write by that preview; compare all durable file bytes.
  def durable_snapshot(home)
    Dir.glob(data(home) + '/**/*', File::FNM_DOTMATCH).sort.each_with_object({}) do |path, files|
      next unless File.file?(path)
      next if path.end_with?('.zwc')
      files[path] = Digest::SHA256.file(path).hexdigest
    end
  end

  def test_failure_rolls_back
    snapshot = Marshal.load(Marshal.dump(@snapshot))
    bad = snapshot['plugins'][0].merge('name' => 'missing', 'url' => "file://#{@root}/does-not-exist")
    snapshot['plugins'] << bad
    home = fixture('failure', snapshot)
    before = File.binread(data(home) + '/plugins.json')
    out, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore')
    check('a failed clone rolls back new checkouts and preserves metadata', st.exitstatus == 74 &&
          !File.exist?(checkout(home)) && File.binread(data(home) + '/plugins.json') == before, out)
  end

  def test_existing_checkout
    home = fixture('existing')
    command(home, 'plugin', 'restore')
    File.write(checkout(home) + '/portable.zsh', '# local edit')
    command(home, 'plugin', 'restore')
    check('repeat restore keeps local checkout edits', File.read(checkout(home) + '/portable.zsh') == '# local edit')
  end

  def test_backup_failure_rolls_back
    home = fixture('backup-failure')
    FileUtils.rm_rf(data(home) + '/backup')
    File.write(data(home) + '/backup', 'blocked')
    before = File.binread(data(home) + '/plugins.json')
    out, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore')
    check('backup failure rolls back new checkouts before changing metadata', st.exitstatus == 73 &&
          !File.exist?(checkout(home)) && File.binread(data(home) + '/plugins.json') == before, out)
  end

  def test_destination_collision
    %w[directory symlink dangling].each do |kind|
      home = fixture(kind)
      target = @root + '/untouched-' + kind
      FileUtils.mkdir_p(target)
      if kind == 'directory'
        FileUtils.mkdir_p(checkout(home))
      else
        File.symlink(kind == 'dangling' ? target + '/absent' : target, checkout(home))
      end
      before = File.binread(data(home) + '/plugins.json')
      out, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore')
      check("refuses #{kind} collision", st.exitstatus == 78 && File.binread(data(home) + '/plugins.json') == before && Dir.exist?(target), out)
    end
  end

  def test_invalid_metadata
    snapshot = Marshal.load(Marshal.dump(@snapshot))
    snapshot['plugins'][0]['name'] = '../outside'
    home = fixture('invalid', snapshot)
    out, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore')
    check('relocation still validates plugin names', st.exitstatus == 78 && !File.exist?(data(home) + '/outside'), out)
  end

  def test_unpinned_branch
    snapshot = Marshal.load(Marshal.dump(@snapshot))
    snapshot['plugins'][0]['git'] = { 'ref_type' => 'Branch', 'branch' => 'main', 'commit' => @sha }
    home = fixture('branch', snapshot)
    command(home, 'plugin', 'restore')
    check('unpinned restore uses recorded commit and keeps branch tracking', git('-C', checkout(home), 'rev-parse', 'HEAD') == @sha &&
          git('-C', checkout(home), 'branch', '--show-current') == 'main')
    command(home, 'plugin', 'update', 'origin')
    check('explicit update still advances a restored branch', git('-C', checkout(home), 'rev-parse', 'HEAD') != @sha)
  end

  def test_tag_without_commit
    git('-C', @repo, 'tag', 'v1', @sha)
    snapshot = Marshal.load(Marshal.dump(@snapshot))
    snapshot['plugins'][0]['git'] = { 'ref_type' => 'Tag', 'tag' => 'v1', 'pinned_ref' => 'v1' }
    snapshot['plugins'][0]['enabled'] = false
    home = fixture('tag', snapshot)
    command(home, 'plugin', 'restore')
    check('tag-only metadata restores disabled plugin without enabling it', git('-C', checkout(home), 'rev-parse', 'HEAD') == @sha &&
          config(home)['plugins'][0]['enabled'] == false)
  end

  def test_missing_add_reports_recovery
    home = fixture('missing-add')
    p = config(home)
    p['plugins'][0]['installed_path'] = checkout(home)
    File.write(data(home) + '/plugins.json', JSON.pretty_generate(p))
    out, st = Open3.capture2e(env(home), BIN, 'plugin', 'add', "file://#{@repo}")
    check('add reports missing checkout with recovery command', st.exitstatus == 66 && out.include?('plugin restore'), out)
  end

  def test_empty_and_wrong_origin
    home = fixture('empty', { 'version' => '1.0', 'plugins' => [] })
    command(home, 'plugin', 'restore')
    check('empty configuration needs no checkout', !File.exist?(checkout(home)) && config(home)['plugins'].empty?)
    home = fixture('wrong-origin')
    command(home, 'plugin', 'restore')
    git('-C', checkout(home), 'remote', 'set-url', 'origin', "file://#{@root}/other")
    out, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore')
    check('existing checkout from another origin is refused', st.exitstatus == 78 && out.include?('different origin'), out)
  end

  def test_arguments
    home = fixture('args')
    _, st = Open3.capture2e(env(home), BIN, 'plugin', 'restore', 'unexpected')
    check('restore rejects extra arguments', st.exitstatus == 64)
  end
end

PluginRestoreTest.new.run if __FILE__ == $0
