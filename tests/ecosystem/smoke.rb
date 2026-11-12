#!/usr/bin/env ruby
# Real upstream releases from fetch.py. No stand-in mise/direnv binaries.
# Initializers and explicit environment diffs are tested; this is not a
# full interactive usability test of every theme, widget, or plugin.
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'shellwords'

class EcosystemSmoke
  def initialize
    @tools = File.expand_path(ENV.fetch('WAYU_ECOSYSTEM_DIR'))
    @wayu = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
    @root = Dir.mktmpdir('wayu-ecosystem-')
    @shells = %w[zsh bash fish].map do |name|
      exe = ENV.fetch('PATH').split(':').map { |d| "#{d}/#{name}" }.find { |p| File.executable?(p) }
      raise "Missing shell #{name}" unless exe
      [name, exe]
    end.to_h
  end

  def run
    %w[mise direnv starship chezmoi sheldon].each do |tool|
      exe = "#{@tools}/bin/#{tool}"
      raise "Missing pinned #{tool}" unless File.executable?(exe)
      puts run!(base_env(@root), exe, '--version').lines.first
    end
    @shells.each_key do |shell|
      external_tools(shell)
    end
    chezmoi
    sheldon
    managers
    fisher
    puts 'PASS all pinned ecosystem smoke checks'
  ensure
    FileUtils.rm_rf(@root)
  end

  def base_env(home)
    { 'HOME' => home, 'SHELL' => '/bin/zsh', 'TERM' => 'xterm-256color', 'LANG' => 'C.UTF-8',
      'PATH' => "#{@tools}/bin:#{File.dirname(@wayu)}:#{ENV.fetch('PATH')}",
      'WAYU_CONFIG_DIR' => "#{home}/.config/wayu", 'WAYU_DATA_DIR' => "#{home}/.local/share/wayu",
      'XDG_CONFIG_HOME' => "#{home}/.config", 'XDG_DATA_HOME' => "#{home}/.local/share",
      'XDG_CACHE_HOME' => "#{home}/.cache", 'XDG_STATE_HOME' => "#{home}/.local/state",
      'TMPDIR' => "#{home}/tmp/", 'NO_COLOR' => '1', 'GIT_CONFIG_GLOBAL' => '/dev/null',
      'GIT_CONFIG_NOSYSTEM' => '1', 'MISE_YES' => '1', 'MISE_QUIET' => '1', 'USER' => 'wayu-test' }
  end

  def run!(env, *cmd)
    out, err, status = Open3.capture3(env, *cmd, chdir: env['HOME'], stdin_data: '', unsetenv_others: true)
    raise "#{cmd.inspect}: #{status.exitstatus}\n#{out}\n#{err}" unless status.success?
    out
  end

  def setup(name)
    home = "#{@root}/#{name}"
    FileUtils.mkdir_p([home, "#{home}/tmp"])
    env = base_env(home)
    %w[zsh bash fish].each { |shell| run!(env, @wayu, 'init', '--shell', shell) }
    run!(env, @wayu, 'const', 'add', 'READINESS_GLOBAL_MARK', 'global-ok')
    run!(env, @wayu, 'alias', 'add', 'readiness_alias', 'echo alias-ok')
    [home, env]
  end

  def quote(text)
    Shellwords.escape(text)
  end

  def shell!(env, shell, script)
    env = env.merge('SHELL' => @shells.fetch(shell))
    args = shell == 'fish' ? ['--no-config', '-i', '-c'] : ['-f', '-i', '-c']
    args = ['--noprofile', '--norc', '-i', '-c'] if shell == 'bash'
    run!(env, @shells.fetch(shell), *args, script)
  end

  def apply(tool, shell)
    args = tool == 'mise' ? "env -s #{shell}" : "export #{shell}"
    shell == 'fish' ? "#{tool} #{args} | source" : "eval \"$(#{tool} #{args})\""
  end

  def activate(tool, shell)
    action = { 'mise' => 'activate', 'starship' => 'init', 'direnv' => 'hook' }.fetch(tool)
    shell == 'fish' ? "#{tool} #{action} #{shell} | source" : "eval \"$(#{tool} #{action} #{shell})\""
  end

  def external_tools(shell)
    home, env = setup("tools-#{shell}")
    project = "#{home}/project"
    FileUtils.mkdir_p(project)
    File.write("#{project}/mise.toml", "[env]\nMISE_PROJECT_MARK = \"mise-ok\"\n")
    File.write("#{project}/.envrc", "export DIRENV_PROJECT_MARK=direnv-ok\n")
    File.write("#{home}/.config/starship.toml", "format = 'READY> '\n")
    init = "source #{quote(env['WAYU_DATA_DIR'] + "/init.#{shell}")}; "
    # An unapproved .envrc must not export the fixture variable.
    denied = shell!(env, shell, init + "cd #{quote(project)}; #{apply('direnv', shell)}; echo denied=\"$DIRENV_PROJECT_MARK\"")
    raise "direnv authorized unexpectedly: #{denied}" if denied.include?('direnv-ok')
    run!(env, "#{@tools}/bin/direnv", 'allow', project)
    run!(env, "#{@tools}/bin/mise", 'trust', "#{project}/mise.toml")
    script = init + %w[mise starship direnv].map { |t| activate(t, shell) }.join('; ') + '; '
    before = shell == 'fish' ? 'set before (functions fish_prompt | string collect)' :
             (shell == 'zsh' ? 'before=$PROMPT' : 'before=$PS1')
    after = shell == 'fish' ? 'test "$before" = "$(functions fish_prompt | string collect)"' :
            (shell == 'zsh' ? '[ "$before" = "$PROMPT" ]' : '[ "$before" = "$PS1" ]')
    script += before + '; ' + init + after + '; or_exit_placeholder; '
    script = script.sub('; or_exit_placeholder', shell == 'fish' ? '; or exit 1' : ' || exit 1')
    script += "starship prompt; cd #{quote(project)}; #{apply('mise', shell)}; #{apply('direnv', shell)}; "
    script += 'echo "inside=$MISE_PROJECT_MARK/$DIRENV_PROJECT_MARK/$READINESS_GLOBAL_MARK"; '
    script += "cd #{quote(home)}; #{apply('mise', shell)}; #{apply('direnv', shell)}; "
    script += 'echo "outside=$MISE_PROJECT_MARK/$DIRENV_PROJECT_MARK/$READINESS_GLOBAL_MARK"'
    out = shell!(env, shell, script)
    unless out.include?('READY>') && out.include?('inside=mise-ok/direnv-ok/global-ok') && out.include?('outside=//global-ok')
      raise "#{shell}: environment/prompt contract failed\n#{out}"
    end
    puts "PASS #{shell}: real mise/Starship/direnv activation order, prompt preservation, authorized environment enter/leave"
  end

  def chezmoi
    home, env = setup('chezmoi')
    state = "#{@root}/chezmoi-source"
    cfg = "#{@root}/chezmoi-config/config.toml"
    FileUtils.mkdir_p(File.dirname(cfg))
    File.write(cfg, '')
    target = env['WAYU_DATA_DIR'] + '/entries.json'
    cmd = ["#{@tools}/bin/chezmoi", '--config', cfg, '--source', state, '--destination', home]
    run!(env, *cmd, 'add', target)
    run!(env, @wayu, 'const', 'add', 'AFTER_TRACKING', 'captured')
    run!(env, *cmd, 're-add', target)
    FileUtils.rm(target)
    run!(env, *cmd, '--force', 'apply', target)
    raise 'chezmoi lost CLI mutation' unless run!(env, @wayu, 'const', 'get', 'AFTER_TRACKING').strip == 'captured'
    puts 'PASS chezmoi: capture CLI mutations with re-add, then reconstruct with apply'
  end

  def managers
    %w[oh-my-zsh antidote].each do |manager|
      home, env = setup(manager)
      fixture = "#{home}/external-plugin"
      FileUtils.mkdir_p(fixture)
      File.write("#{fixture}/external-plugin.plugin.zsh", "(( EXTERNAL_LOADS += 1 ))\nexternal_fn() { echo external-ok; }\n")
      File.write("#{fixture}/_external_cmd", "#compdef external_cmd\n_arguments '*: :()'\n")
      init = "source #{quote(env['WAYU_DATA_DIR'] + '/init.zsh')}; "
      if manager == 'oh-my-zsh'
        custom = "#{home}/custom"
        FileUtils.mkdir_p("#{custom}/plugins")
        FileUtils.cp_r(fixture, "#{custom}/plugins/external-plugin")
        loader = "ZSH=#{quote(@tools + '/src/oh-my-zsh')}; ZSH_CUSTOM=#{quote(custom)}; ZSH_THEME=''; plugins=(external-plugin); zstyle ':omz:update' mode disabled; source \"$ZSH/oh-my-zsh.sh\"; "
      else
        File.write("#{home}/plugins.txt", "#{fixture}\n")
        loader = "source #{quote(@tools + '/src/antidote/antidote.zsh')}; antidote load #{quote(home + '/plugins.txt')}; fpath=(#{quote(fixture)} $fpath); autoload -Uz compinit; compinit; "
      end
      out = shell!(env, 'zsh', init + loader + init + 'external_fn; print "loads=$EXTERNAL_LOADS completion=${_comps[external_cmd]-none} global=$READINESS_GLOBAL_MARK"; alias readiness_alias')
      raise "#{manager}: #{out}" unless out.include?('external-ok') && out.include?('loads=1 completion=_external_cmd global=global-ok') && out.include?('alias-ok')
      puts "PASS #{manager}: wayu first, one external plugin load, completion registration, retained entries"
    end
  end

  def sheldon
    home, env = setup('sheldon')
    plugin = "#{home}/external-plugin"
    FileUtils.mkdir_p([plugin, "#{home}/.config/sheldon"])
    File.write("#{plugin}/external.zsh", "sheldon_fixture() { echo sheldon-ok; }\n")
    File.write("#{home}/.config/sheldon/plugins.toml", "shell = \"zsh\"\n[plugins.fixture]\nlocal = \"#{plugin}\"\nuse = [\"external.zsh\"]\n")
    generated = run!(env, "#{@tools}/bin/sheldon", 'source')
    File.write("#{home}/sheldon.zsh", generated)
    init = quote(env['WAYU_DATA_DIR'] + '/init.zsh')
    out = shell!(env, 'zsh', "source #{init}; source #{quote(home + '/sheldon.zsh')}; sheldon_fixture; echo $READINESS_GLOBAL_MARK")
    raise "Sheldon static loader: #{out}" unless out.include?('sheldon-ok') && out.include?('global-ok')
    puts 'PASS Sheldon: actual source generation and static loader alongside wayu'
  end

  def fisher
    home, env = setup('fisher')
    fixture = "#{home}/fish-plugin"
    FileUtils.mkdir_p(["#{fixture}/functions", "#{fixture}/conf.d", "#{fixture}/completions"])
    File.write("#{fixture}/functions/external_fish.fish", "function external_fish; echo fish-ok; end\n")
    File.write("#{fixture}/conf.d/external_fish.fish", "function _fixture_install --on-event external_fish_install; set -gx FISH_INSTALL_MARK installed; end\n")
    File.write("#{fixture}/completions/external_fish.fish", "complete -c external_fish -a completion-ok\n")
    command(env, 'fish', "source #{quote(@tools + '/src/fisher/functions/fisher.fish')}; fisher install #{quote(fixture)}; source #{quote(env['WAYU_DATA_DIR'] + '/init.fish')}; external_fish; echo \"event=$FISH_INSTALL_MARK global=$READINESS_GLOBAL_MARK\"; complete -C 'external_fish '")
  end

  def command(env, shell, script)
    out = shell!(env, shell, script)
    raise "Fisher: #{out}" unless out.include?('fish-ok') && out.include?('event=installed global=global-ok') && out.include?('completion-ok')
    puts 'PASS Fisher: Fisher owns install event, function and completion; wayu preserves them'
  end
end

EcosystemSmoke.new.run
