#!/usr/bin/env ruby
# Startup performance budget (OKAMI-178): sourcing init.<ext> with a fixed,
# realistic config must stay within a generous budget over an empty shell.
#
# CI runners are noisy, so this guards against regressions (an accidental
# fork per entry, a compinit without cache, a slow loop), not against a few
# milliseconds: each shell is timed RUNS times after warm-up (the first run
# builds .zcompdump), and the MEDIAN of (init - empty shell) is compared with
# the budget. Override with WAYU_STARTUP_BUDGET_MS (applies to every shell).

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class StartupBudgetTest
  include WayuTestHelper

  RUNS = 9
  WARMUP = 2
  # Milliseconds of overhead over `<shell> -c :` (measured locally at a few
  # ms; budgets leave ample room for slow, shared CI machines).
  BUDGET_MS = { 'zsh' => 150, 'bash' => 150, 'fish' => 250 }.freeze

  def initialize
    setup_test_env
  end

  def run
    puts '🚀 Testing shell startup time against the budget...'
    puts

    begin
      build_project
      shells.each { |sh| test_budget(sh) }
    ensure
      teardown_test_env
    end

    print_summary('startup budget')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def shells
    found = [%w[zsh zsh -f], %w[bash bash --norc]]
    fish = %w[/opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish].find { |f| File.executable?(f) }
    found << ['fish', fish, '--no-config'] if fish
    found.map { |name, exe, flag| { name: name, exe: exe, flag: flag } }
  end

  # 40 paths (half existing), 60 aliases, 40 env vars, a lazy tool.
  def toml(home)
    t = +"[paths]\n"
    40.times do |i|
      dir = "#{home}/bins/b#{i}"
      FileUtils.mkdir_p(dir) if i.even?
      t << "p#{i} = \"#{dir}\"\n"
    end
    t << "gobin = \"$GOPATH/bin\"\n\n[env]\nGOPATH = \"$HOME/go\"\n"
    40.times { |i| t << "BUDGET_E#{i} = \"value-#{i}:${HOME}/x\"\n" }
    t << "\n[aliases]\n"
    60.times { |i| t << "ba#{i} = \"echo alias #{i} && ls -la\"\n" }
    t << "\n[tools]\nsdk = { kind = \"lazy\", init_script = \"~/.sdk/init.sh\", hook_commands = [\"sdk\"] }\n"
    t
  end

  def now_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end

  def median(xs)
    s = xs.sort
    s[s.size / 2]
  end

  def time_runs(env, sh, script)
    (WARMUP + RUNS).times.map do
      t0 = now_ms
      _, err, st = Open3.capture3(env, sh[:exe], sh[:flag], '-c', script)
      raise "#{sh[:name]} failed (#{st.exitstatus}): #{err[0, 300]}" unless st.success? && err.empty?
      now_ms - t0
    end.drop(WARMUP)
  end

  def test_budget(sh)
    budget = (ENV['WAYU_STARTUP_BUDGET_MS'] || BUDGET_MS[sh[:name]]).to_f
    print "Test: #{sh[:name]} init.#{sh[:name]} startup within #{budget.round}ms of an empty shell... "
    home = "#{@tmp_home}/#{sh[:name]}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p("#{home}/.config")
    env = { 'HOME' => home, 'SHELL' => "/bin/#{sh[:name]}", 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin',
            'ZDOTDIR' => nil, 'WAYU_CONFIG' => nil, 'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil }
    Open3.capture3(env, @wayu_bin, 'init', '--shell', sh[:name])
    cfg = "#{home}/.config/wayu"
    File.write("#{cfg}/wayu.toml", toml(home))
    Open3.capture3(env, @wayu_bin, 'completions', 'generate')
    _, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
    unless bst.success?
      check(false, "build failed: #{berr[0, 300]}")
      return
    end
    begin
      base = median(time_runs(env, sh, ':'))
      init = median(time_runs(env, sh, "source '#{cfg}/init.#{sh[:name]}'"))
    rescue RuntimeError => e
      check(false, e.message)
      return
    end
    over = init - base
    check(over <= budget, format('%.1fms over an empty shell (init %.1fms, empty %.1fms)', over, init, base),
          format('%.1fms', over))
  end

  def check(ok, detail, pass_note = nil)
    if ok
      puts "✓ (#{pass_note})"; @passed += 1
    else
      puts '✗'; puts "  #{detail}"; @failed += 1
    end
  end
end

if __FILE__ == $0
  StartupBudgetTest.new.run
end
