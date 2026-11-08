#!/usr/bin/env ruby
# Integration tests for secret handling (OKAMI-206/207/208):
#   * wayu.toml, backups and generated core files are owner-only;
#   * `get` is exact-match only and never prints another entry's value;
#   * dry-run / search / export previews mask secret-looking values;
#   * list views (`const list`, `--full`, `--json`, `toml show`) mask them
#     unless `--reveal`; `const get` keeps printing the real value.
# All values below are fake. Runs in a temporary HOME.

require 'open3'
require 'json'
require 'fileutils'
require_relative 'test_helper'

class SecretsIntegrationTest
  include WayuTestHelper

  SECRET = 'fake-secret-value-0001'.freeze
  DB_PW  = 'fakepw0002'.freeze

  def initialize
    setup_test_env
  end

  def run
    puts '🔒 Testing secret handling...'
    puts

    begin
      build_project
      initialize_wayu
      seed

      test_toml_and_generated_files_owner_only
      test_backups_owner_only
      test_legacy_backup_modes_repaired
      test_const_get_exact_prints_value
      test_const_get_prefix_miss
      test_const_get_case_mismatch_miss
      test_alias_get_prefix_miss
      test_path_get_prefix_miss
      test_dry_run_const_add_masks
      test_dry_run_alias_add_hides_env
      test_dry_run_const_rm_shows_name_only
      test_search_masks_and_skips_values
      test_export_dry_run_masks
      test_const_list_masks
      test_const_list_full_masks_external
      test_const_list_json_masks
      test_const_list_reveal_shows
      test_const_get_unmasked_in_clean_env
      test_toml_show_masks_unless_reveal
      test_reveal_rejected_elsewhere
    ensure
      teardown_test_env
    end

    print_summary('secrets')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def run_split(args)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'NO_COLOR' => '1')
    project_root = File.expand_path('../..', __dir__)
    out, err, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  end

  # Fully controlled environment (unsetenv_others): the caller's real
  # environment — which may hold real secrets — never reaches wayu, so
  # `--full` / `--reveal` output can only contain the fake values here.
  EXT_SECRET = 'fake-ext-secret-0004'.freeze

  def run_clean(args)
    env = { 'HOME' => @tmp_home, 'PATH' => '/usr/bin:/bin', 'SHELL' => '/bin/zsh',
            'NO_COLOR' => '1', 'FAKE_EXT_API_KEY' => EXT_SECRET }.merge(sanitizer_env)
    project_root = File.expand_path('../..', __dir__)
    out, err, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root, unsetenv_others: true)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  end

  def check(label, ok, detail = '')
    if ok
      puts '✓'
      @passed += 1
    else
      puts '✗'
      puts "  #{label}"
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def mode(path)
    File.stat(path).mode & 0o777
  end

  def seed
    run_split("const add FIREWORKS_AI_API_KEY #{SECRET}")
    run_split("const add DATABASE_URL 'postgres://app:#{DB_PW}@localhost/app'")
    run_split('const add EDITOR nvim')
    run_split("alias add gst 'git status'")
    FileUtils.mkdir_p("#{@tmp_home}/secret_bin_dir")
    run_split("path add #{@tmp_home}/secret_bin_dir")
  end

  def test_toml_and_generated_files_owner_only
    print 'Test 1: wayu.toml and generated core files are 0600... '
    files = ["#{@config_dir}/wayu.toml"] + Dir.glob("#{@data_dir}/{core,lazy,login,helpers}.zsh")
    bad = files.reject { |f| mode(f) == 0o600 }.map { |f| "#{File.basename(f)}=#{format('%o', mode(f))}" }
    check('files wider than 0600', bad.empty? && files.size >= 2, bad.join(' '))
  end

  def test_backups_owner_only
    print 'Test 2: backup dir 0700, backups 0600... '
    dir = "#{@data_dir}/backup"
    backups = Dir.glob("#{dir}/*")
    bad = backups.reject { |f| mode(f) == 0o600 }
    check("dir=#{format('%o', mode(dir))} bad=#{bad}",
          mode(dir) == 0o700 && !backups.empty? && bad.empty?)
  end

  def test_legacy_backup_modes_repaired
    print 'Test 3: next backup tightens legacy 0755/0644 modes... '
    dir = "#{@data_dir}/backup"
    File.chmod(0o755, dir)
    Dir.glob("#{dir}/*").each { |f| File.chmod(0o644, f) }
    File.chmod(0o644, "#{@data_dir}/core.zsh")
    run_split('const add REPAIR_TRIGGER 1')
    bad = Dir.glob("#{dir}/*").reject { |f| mode(f) == 0o600 }
    check("dir=#{format('%o', mode(dir))} core=#{format('%o', mode("#{@data_dir}/core.zsh"))} bad=#{bad.size}",
          mode(dir) == 0o700 && bad.empty? && mode("#{@data_dir}/core.zsh") == 0o600)
  end

  def test_const_get_exact_prints_value
    print 'Test 4: const get EXACT prints value, exit 0... '
    out, _err, status = run_split('const get FIREWORKS_AI_API_KEY')
    check("exit=#{status.exitstatus} out=#{out.inspect}", status.success? && out.strip == SECRET)
  end

  def test_const_get_prefix_miss
    print 'Test 5: const get FIRE misses (exit 65), no value anywhere, names on stderr... '
    out, err, status = run_split('const get FIRE')
    ok = status.exitstatus == 65 && out.strip.empty? &&
         !(out + err).include?(SECRET) && err.include?('FIREWORKS_AI_API_KEY')
    check("exit=#{status.exitstatus} out=#{out.inspect} err=#{err.inspect}", ok)
  end

  def test_const_get_case_mismatch_miss
    print 'Test 6: const get with wrong case is a miss... '
    out, err, status = run_split('const get fireworks_ai_api_key')
    check("exit=#{status.exitstatus}", status.exitstatus == 65 && out.strip.empty? && !(out + err).include?(SECRET))
  end

  def test_alias_get_prefix_miss
    print 'Test 7: alias get prefix misses (exit 65)... '
    out, err, status = run_split('alias get gs')
    check("exit=#{status.exitstatus} out=#{out.inspect}",
          status.exitstatus == 65 && out.strip.empty? && !err.include?('git status') && err.include?('gst'))
  end

  def test_path_get_prefix_miss
    print 'Test 8: path get prefix misses (exit 65)... '
    out, _err, status = run_split("path get #{@tmp_home}/secret_bin")
    check("exit=#{status.exitstatus} out=#{out.inspect}", status.exitstatus == 65 && out.strip.empty?)
  end

  def test_dry_run_const_add_masks
    print 'Test 9: --dry-run const add masks secret value, shows only changed key... '
    out, err, status = run_split('--dry-run const add NEW_API_TOKEN fake-new-token-0003')
    all = out + err
    ok = status.success? && all.include?('NEW_API_TOKEN') && all.include?('********') &&
         !all.include?('fake-new-token-0003') && !all.include?(SECRET) && !all.include?(DB_PW) &&
         !all.include?('EDITOR')
    check(all, ok)
  end

  def test_dry_run_alias_add_hides_env
    print 'Test 10: --dry-run alias add does not print [env]... '
    out, err, status = run_split("--dry-run alias add zz 'echo hi'")
    all = out + err
    ok = status.success? && all.include?('zz') && !all.include?(SECRET) && !all.include?(DB_PW) &&
         !all.include?('gst')
    check(all, ok)
  end

  def test_dry_run_const_rm_shows_name_only
    print 'Test 11: --dry-run const rm shows the name, not the value... '
    out, err, status = run_split('--dry-run const rm FIREWORKS_AI_API_KEY')
    all = out + err
    check(all, status.success? && all.include?('FIREWORKS_AI_API_KEY') && !all.include?(SECRET))
  end

  def test_search_masks_and_skips_values
    print 'Test 12: search masks secret values and never matches inside constant values... '
    out_name, err_name, = run_split('search FIREWORKS')
    out_val, err_val, = run_split("search #{DB_PW}")
    ok = (out_name + err_name).include?('FIREWORKS_AI_API_KEY') && !(out_name + err_name).include?(SECRET) &&
         !(out_val + err_val).include?('DATABASE_URL') && !(out_val + err_val).include?(DB_PW + '@')
    check("name=#{out_name} value=#{out_val}", ok)
  end

  def test_export_dry_run_masks
    print 'Test 13: export --dry-run preview masks secrets... '
    out, err, status = run_split('export --dry-run')
    all = out + err
    ok = status.success? && all.include?('FIREWORKS_AI_API_KEY') && !all.include?(SECRET) && !all.include?(DB_PW)
    check(all, ok)
  end

  def test_const_list_masks
    print 'Test 14: const list masks secret-looking values... '
    out, err, status = run_clean('const list')
    all = out + err
    ok = status.success? && all.include?('FIREWORKS_AI_API_KEY') && all.include?('********') &&
         all.include?('nvim') && !all.include?(SECRET) && !all.include?(DB_PW) && all.include?('--reveal')
    check(all, ok)
  end

  def test_const_list_full_masks_external
    print 'Test 15: const list --full masks external secrets too... '
    out, err, status = run_clean('const list --full')
    all = out + err
    ok = status.success? && all.include?('FAKE_EXT_API_KEY') && !all.include?(EXT_SECRET) &&
         !all.include?(SECRET) && !all.include?(DB_PW)
    check(all, ok)
  end

  def test_const_list_json_masks
    print 'Test 16: --json const list (with and without --full) masks values... '
    plain_out, _, plain_status = run_clean('--json const list')
    full_out, _, full_status = run_clean('--json const list --full')
    plain = JSON.parse(plain_out)['constants'].to_h { |c| [c['constant'], c['value']] }
    full = JSON.parse(full_out)['constants'].to_h { |c| [c['constant'], c['value']] }
    ok = plain_status.success? && full_status.success? &&
         plain['FIREWORKS_AI_API_KEY'] == '********' && plain['DATABASE_URL'] == '********' &&
         plain['EDITOR'] == 'nvim' && !plain.key?('FAKE_EXT_API_KEY') &&
         full['FIREWORKS_AI_API_KEY'] == '********' && full['FAKE_EXT_API_KEY'] == '********' &&
         !(plain_out + full_out).include?(SECRET) && !(plain_out + full_out).include?(EXT_SECRET)
    check("plain=#{plain_out} full=#{full_out}", ok)
  rescue JSON::ParserError => e
    check("invalid JSON: #{e.message}", false)
  end

  def test_const_list_reveal_shows
    print 'Test 17: --reveal shows real values (text, --full, --json)... '
    out, err, status = run_clean('const list --reveal')
    full_out, _, full_status = run_clean('--json const list --full --reveal')
    ok = status.success? && full_status.success? && (out + err).include?(SECRET) &&
         full_out.include?(SECRET) && full_out.include?(EXT_SECRET) && !full_out.include?('********')
    check("out=#{out} json=#{full_out}", ok)
  end

  def test_const_get_unmasked_in_clean_env
    print 'Test 18: const get still prints the real value... '
    out, _err, status = run_clean('const get FIREWORKS_AI_API_KEY')
    check("exit=#{status.exitstatus} out=#{out.inspect}", status.success? && out.strip == SECRET)
  end

  def test_toml_show_masks_unless_reveal
    print 'Test 19: toml show masks [env] secrets; --reveal shows them... '
    out, _, status = run_clean('toml show')
    rout, _, rstatus = run_clean('toml show --reveal')
    ok = status.success? && rstatus.success? && out.include?('FIREWORKS_AI_API_KEY = "********"') &&
         !out.include?(SECRET) && !out.include?(DB_PW) && out.include?('nvim') && out.end_with?("\n") &&
         rout.include?(SECRET) && rout == File.read("#{@config_dir}/wayu.toml")
    check("masked=#{out}", ok)
  end

  def test_reveal_rejected_elsewhere
    print 'Test 20: --reveal is a usage error on commands without masked lists... '
    _, err, status = run_clean('path list --reveal')
    check("exit=#{status.exitstatus} err=#{err}", status.exitstatus == 64 && err.include?('--reveal'))
  end
end

SecretsIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
