#!/usr/bin/env ruby
# Integration tests for hooks.conf: hooks run outside the config lock with a
# deadline (OKAMI-299), their output is shown (OKAMI-336), remove hooks get
# the entry's value (OKAMI-334), and only quotes wrapping the whole command
# are stripped (OKAMI-335). Also `function add` without an editor (OKAMI-336).

require 'open3'
require 'fileutils'
require 'timeout'
require_relative 'test_helper'

class HooksIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🪝 Testing hooks integration..."
    puts

    begin
      build_project
      initialize_wayu(shell: 'zsh')

      test_hooks_can_run_wayu
      test_hook_timeout
      test_hook_output_shown
      test_remove_hooks_get_value
      test_quotes_not_wrapping_whole_command_kept
      test_function_add_without_editor
    ensure
      teardown_test_env
    end

    print_summary("hooks")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def hooks_file; "#{@config_dir}/hooks.conf"; end

  def check(label, condition, detail = nil)
    print "#{label}... "
    if condition
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}" if detail
      @failed += 1
    end
  end

  # run_wayu with extra env, killed after `limit` seconds (a deadlock must
  # fail the test, not hang the suite). Returns [output, status, seconds]
  # (status nil when killed).
  def run_limited(args, env: {}, limit: 20)
    full = ENV.to_h.merge('HOME' => @tmp_home).merge(env)
    project_root = File.expand_path('../..', __dir__)
    t0 = Time.now
    Open3.popen3(full, "#{@wayu_bin} #{args}", chdir: project_root, pgroup: true) do |i, o, e, w|
      i.close
      out_t = Thread.new { o.read }
      err_t = Thread.new { e.read }
      unless w.join(limit)
        Process.kill('KILL', -w.pid) rescue nil
        w.join
        return ["#{out_t.value}#{err_t.value}", nil, Time.now - t0]
      end
      [(out_t.value + err_t.value).force_encoding('UTF-8'), w.value, Time.now - t0]
    end
  end

  # Regression (OKAMI-299): path hooks ran under the config lock, so a hook
  # calling wayu (here: `alias add`, `build`) waited for it forever.
  def test_hooks_can_run_wayu
    dir = "#{@scratch}/hookdir"
    FileUtils.mkdir_p(dir)
    File.write(hooks_file, "pre_path_add = #{@wayu_bin} build >/dev/null 2>&1\n" \
                           "post_path_add = #{@wayu_bin} alias add fromhook 'echo hi' >/dev/null 2>&1\n" \
                           "pre_path_remove = #{@wayu_bin} build >/dev/null 2>&1\n" \
                           "post_path_remove = #{@wayu_bin} alias rm fromhook >/dev/null 2>&1\n")
    out, st, = run_limited("path add #{dir}")
    added = store_map('aliases')['fromhook'] == 'echo hi'
    out2, st2, = run_limited("path rm #{dir}")
    removed = !store_map('aliases').key?('fromhook')
    FileUtils.rm_f(hooks_file)
    check('path add/rm hooks that run wayu complete (no deadlock on the config lock)',
          st&.success? && added && st2&.success? && removed,
          "add=#{st.inspect} added=#{added} rm=#{st2.inspect} removed=#{removed} out=#{out}#{out2}")
  end

  # OKAMI-299: CLI hooks have a deadline (hooks.conf `timeout`).
  def test_hook_timeout
    File.write(hooks_file, "timeout = 1\npost_alias_add = sleep 30\n")
    out, st, secs = run_limited('alias add slowhook ls', limit: 15)
    FileUtils.rm_f(hooks_file)
    check('a hook over hooks.conf timeout is killed with a warning; the command succeeds',
          st&.success? && secs < 10 && out.include?('post_alias_add hook timed out after 1 s'),
          "status=#{st.inspect} secs=#{secs} out=#{out}")
  end

  # OKAMI-336: hook output was sent to /dev/null.
  def test_hook_output_shown
    File.write(hooks_file, "post_alias_add = echo hook-out-{name}; echo hook-err >&2\n")
    out, st, = run_limited('alias add shownhook ls')
    FileUtils.rm_f(hooks_file)
    check('hook stdout and stderr are shown',
          st&.success? && out.include?('hook-out-shownhook') && out.include?('hook-err'),
          "status=#{st.inspect} out=#{out}")
  end

  # OKAMI-334: remove hooks got an empty {value}.
  def test_remove_hooks_get_value
    log = "#{@scratch}/rm-hooks.log"
    File.write(hooks_file, "pre_alias_remove = echo pre:{name}={value} >> #{log}\n" \
                           "post_alias_remove = echo post:{name}={value} >> #{log}\n" \
                           "post_constant_remove = echo const:{name}={value} >> #{log}\n")
    run_limited("alias add rmhook 'git status'")
    run_limited('const add RMHOOK_C myvalue')
    _, st, = run_limited('alias rm rmhook')
    _, st2, = run_limited('const rm RMHOOK_C')
    FileUtils.rm_f(hooks_file)
    logged = File.exist?(log) ? File.read(log) : ''
    check('remove hooks get the removed alias command / constant value as {value}',
          st&.success? && st2&.success? &&
          logged == "pre:rmhook=git status\npost:rmhook=git status\nconst:RMHOOK_C=myvalue\n",
          "log=#{logged.inspect}")
  end

  # OKAMI-335: `"/bin/echo" {path} "done"` lost its first and last quote and
  # became an invalid hook (every write exited 78).
  def test_quotes_not_wrapping_whole_command_kept
    dir = "#{@scratch}/quotedir"
    FileUtils.mkdir_p(dir)
    File.write(hooks_file, %(post_path_add = "/bin/echo" {path} "done"\n) +
                           %(post_path_remove = "echo 'wrapped ok'"\n))
    out, st, = run_limited("path add #{dir}")
    out2, st2, = run_limited("path rm #{dir}")
    FileUtils.rm_f(hooks_file)
    check('quotes are stripped only when they wrap the whole hook command',
          st&.success? && out.include?("#{dir} done") && st2&.success? && out2.include?('wrapped ok'),
          "add=#{st.inspect} rm=#{st2.inspect} out=#{out}#{out2}")
  end

  # OKAMI-336: with no EDITOR/VISUAL and no terminal, `function add` ran vi
  # (exit 1); it now prints the file like `script new`.
  def test_function_add_without_editor
    out, st, = run_limited('function add noeditfn', env: { 'EDITOR' => nil, 'VISUAL' => nil })
    file = "#{@data_dir}/functions/noeditfn.zsh"
    check('function add without an editor or terminal prints the file and exits 0',
          st&.success? && File.exist?(file) && out.lines.map(&:strip).include?(file),
          "status=#{st.inspect} out=#{out}")
  end
end

if __FILE__ == $0
  HooksIntegrationTest.new.run
end
