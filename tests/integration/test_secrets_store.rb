#!/usr/bin/env ruby
# Integration tests for encrypted secrets (OKAMI-192, Phase 5 C):
# `const add --secret`, the encrypted store, the file key backend, the
# per-session cache sourced by zsh/bash/fish, rekey, lock, tamper handling
# and doctor. Uses `[secrets] backend = "file"` in a temporary HOME and a
# private TMPDIR for the cache: the real keychain, HOME and /tmp are never
# touched. Every value below is fake.

require 'open3'
require 'json'
require 'fileutils'
require_relative 'test_helper'

class SecretsStoreIntegrationTest
  include WayuTestHelper

  TOKEN  = %q(fake-tok-$HOME "dq" 's `bt` \\x).freeze
  MULTI  = "fake-line-1\nfake-line-2".freeze
  PIPED  = 'fake-piped-0003'.freeze

  def initialize
    setup_test_env
    @runtime = "#{@tmp_home}/rt"
    FileUtils.mkdir_p(@runtime)
  end

  def run
    puts '🔐 Testing encrypted secrets...'
    puts

    begin
      build_project
      initialize_wayu
      File.open("#{@config_dir}/wayu.toml", 'a') { |f| f.puts "\n[secrets]\nbackend = \"file\"" }
      w('const add EDITOR nvim')

      test_add_secret
      test_store_and_key_files
      test_no_plaintext_on_disk
      test_list_masked
      test_list_json
      test_get_decrypts
      test_secrets_list_names
      test_zsh_sources_cache
      test_cache_reused_without_regeneration
      test_bash_sources_cache
      test_fish_sources_cache
      test_stdin_value
      test_convert_plain_constant
      test_plain_add_over_secret_refused
      test_dry_run_writes_nothing
      test_secret_flag_rejected_elsewhere
      test_export_eval_has_no_plaintext
      test_rekey
      test_lock
      test_doctor_ok
      test_tamper_warns_and_continues
      test_missing_key_never_replaced
      test_unsafe_key_file_refused
      test_bad_backend_rejected
      test_remove
    ensure
      teardown_test_env
    end

    print_summary('encrypted secrets')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Controlled env: HOME, a private TMPDIR (cache location), no
  # XDG_RUNTIME_DIR, nothing else from the caller's environment.
  def env
    { 'HOME' => @tmp_home, 'PATH' => ENV['PATH'], 'SHELL' => '/bin/zsh', 'NO_COLOR' => '1',
      'TMPDIR' => "#{@runtime}/" }.merge(sanitizer_env)
  end

  # `args`: a string split on spaces, or an argv array (values with spaces/quotes).
  def w(args, stdin: nil)
    argv = args.is_a?(Array) ? args : args.split(' ')
    out, err, st = Open3.capture3(env, @wayu_bin, *argv, stdin_data: stdin || '', unsetenv_others: true)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
  end

  def sh(cmd)
    out, err, st = Open3.capture3(env, *cmd, unsetenv_others: true)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
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
  def store
    "#{@data_dir}/secrets.json"
  end
  def keyfile
    "#{@config_dir}/secret.key"
  end
  def cache_dir
    "#{@runtime}/wayu-#{Process.uid}"
  end
  def caches
    Dir.glob("#{cache_dir}/secrets-*")
  end

  def test_add_secret
    print 'Test 1: const add --secret (value with quotes, $, backslash)... '
    _, err, st = w(['const', 'add', 'FAKE_TOKEN', TOKEN, '--secret'])
    _, err2, st2 = w('const add FAKE_MULTI --secret', stdin: MULTI + "\n")
    check('add failed', st.success? && st2.success?, err + err2)
  end

  def test_store_and_key_files
    print 'Test 2: secrets.json and secret.key are 0600... '
    doc = JSON.parse(File.read(store))
    ok = mode(store) == 0o600 && mode(keyfile) == 0o600 && doc['version'] == 1 &&
         doc['cipher'] == 'chacha20poly1305' && doc['values'].keys.sort == %w[FAKE_MULTI FAKE_TOKEN] &&
         File.read(keyfile).strip.match?(/\A\h{64}\z/)
    check('store/key layout wrong', ok, "store=#{format('%o', mode(store))} key=#{format('%o', mode(keyfile))}")
  end

  def test_no_plaintext_on_disk
    print 'Test 3: no plaintext in config, entries, store, core, backups... '
    files = Dir.glob("#{@tmp_home}/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) && !f.start_with?(@runtime) }
    leaks = files.select { |f| s = File.binread(f); s.include?('fake-tok-') || s.include?('fake-line-1') }
    check('plaintext found', leaks.empty?, leaks.join(' '))
  end

  def test_list_masked
    print 'Test 4: const list masks secrets... '
    out, = w('const list')
    check('list shows value', out.include?('FAKE_TOKEN') && out.include?('********') && !out.include?('fake-tok-'), out)
  end

  def test_list_json
    print 'Test 5: const list --json: "secret": true, no value... '
    out, = w('const list --json')
    row = JSON.parse(out)['constants'].find { |c| c['constant'] == 'FAKE_TOKEN' }
    check('json row wrong', row && row['secret'] == true && !row.key?('value'), out)
  end

  def test_get_decrypts
    print 'Test 6: const get decrypts... '
    out, err, st = w('const get FAKE_TOKEN')
    out2, = w('const get FAKE_MULTI')
    check('get wrong', st.success? && out.chomp == TOKEN && out2.chomp == MULTI, err)
  end

  def test_secrets_list_names
    print 'Test 7: secrets list prints names only... '
    out, = w('secrets list')
    check('list wrong', out.split("\n") == %w[FAKE_MULTI FAKE_TOKEN], out)
  end

  def test_zsh_sources_cache
    print 'Test 8: zsh startup decrypts once into a 0600 cache (0700 dir)... '
    out, err, = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- \"$FAKE_TOKEN\"; print -r -- \"$FAKE_MULTI\"; print -r -- $EDITOR"])
    files = caches
    ok = out == "#{TOKEN}\n#{MULTI}\nnvim\n" && files.size == 1 && mode(files[0]) == 0o600 && mode(cache_dir) == 0o700
    check('zsh did not load the secret', ok, "out=#{out.inspect} err=#{err} caches=#{files}")
  end

  def test_cache_reused_without_regeneration
    print 'Test 9: a current cache is sourced, not rewritten... '
    before = caches.map { |f| [f, File.stat(f).ino] }
    out, = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- \"$FAKE_TOKEN\""])
    after = caches.map { |f| [f, File.stat(f).ino] }
    check('cache rewritten', out.chomp == TOKEN && before == after, "#{before} vs #{after}")
  end

  def test_bash_sources_cache
    print 'Test 10: bash startup loads secrets... '
    w('--shell bash init')
    out, err, = sh(['bash', '--norc', '--noprofile', '-c', "source #{@data_dir}/init.bash; printf '%s\\n' \"$FAKE_TOKEN\""])
    check('bash did not load the secret', out.chomp == TOKEN && caches.any? { |f| f.end_with?('.bash') }, "#{out.inspect} #{err}")
  end

  def test_fish_sources_cache
    print 'Test 11: fish startup loads secrets... '
    fish = `command -v fish 2>/dev/null`.strip
    if fish.empty?
      puts 'skipped (fish not installed)'
      return
    end
    w('--shell fish init')
    out, err, = sh([fish, '--no-config', '-c', "source #{@data_dir}/init.fish; printf '%s\\n' \"$FAKE_TOKEN\""])
    check('fish did not load the secret', out.chomp == TOKEN && caches.any? { |f| f.end_with?('.fish') }, "#{out.inspect} #{err}")
  end

  def test_stdin_value
    print 'Test 12: value from stdin stays off argv... '
    _, err, st = w('const add FAKE_PIPED --secret', stdin: "#{PIPED}\n")
    out, = w('const get FAKE_PIPED')
    check('stdin add failed', st.success? && out.chomp == PIPED, err)
  end

  def test_convert_plain_constant
    print 'Test 13: --secret converts a plain constant; entries.json holds markers only... '
    w('const add FAKE_CONVERT_KEY fake-plain-0004')
    out, err, st = w('const add FAKE_CONVERT_KEY fake-plain-0004 --secret')
    env_entries = JSON.parse(File.read("#{@data_dir}/entries.json"))['env']
    names = env_entries.map { |e| e['name'] }
    marker = env_entries.find { |e| e['name'] == 'FAKE_CONVERT_KEY' }
    got, = w('const get FAKE_CONVERT_KEY')
    check('not converted', st.success? && out.include?('converted') && marker == { 'name' => 'FAKE_CONVERT_KEY', 'secret' => true } &&
          names.include?('FAKE_TOKEN') && names.index('EDITOR') < names.index('FAKE_TOKEN') &&
          !File.read("#{@data_dir}/entries.json").include?('fake-plain') && got.chomp == 'fake-plain-0004', out + err)
  end

  def test_plain_add_over_secret_refused
    print 'Test 14: plain add over a secret is refused (65)... '
    _, err, st = w('const add FAKE_TOKEN plain')
    check('plain add accepted', st.exitstatus == 65 && err.include?('encrypted secret'), err)
  end

  def test_dry_run_writes_nothing
    print 'Test 15: --dry-run writes nothing and never shows the value... '
    before = File.read(store)
    out, err, st = w('const add FAKE_DRY fake-dry-0005 --secret --dry-run')
    check('dry-run wrote', st.success? && File.read(store) == before && !(out + err).include?('fake-dry'), out + err)
  end

  def test_secret_flag_rejected_elsewhere
    print 'Test 16: --secret outside const add is a usage error (64)... '
    _, _, st1 = w('const list --secret')
    _, _, st2 = w('path add /tmp --secret')
    check('accepted', st1.exitstatus == 64 && st2.exitstatus == 64, "#{st1.exitstatus} #{st2.exitstatus}")
  end

  def test_export_eval_has_no_plaintext
    print 'Test 17: export --eval sources the cache, no plaintext... '
    out, = w('export --eval')
    check('eval leaks or lacks loader', out.include?('secrets cache') && !out.include?('fake-tok-'), out)
  end

  def test_rekey
    print 'Test 18: rekey changes the key, keeps values, drops the cache... '
    k1 = File.read(keyfile)
    _, err, st = w('secrets rekey')
    k2 = File.read(keyfile)
    out, = w('const get FAKE_TOKEN')
    check('rekey failed', st.success? && k1 != k2 && mode(keyfile) == 0o600 && out.chomp == TOKEN && caches.empty?, err)
  end

  def test_lock
    print 'Test 19: lock deletes the session cache... '
    sh(['zsh', '-fc', "source #{@data_dir}/init.zsh"])
    had = caches.any?
    _, err, st = w('secrets lock')
    check('cache kept', had && st.success? && caches.empty?, err)
  end

  def test_doctor_ok
    print 'Test 20: doctor checks store, key and decryption... '
    out, = w('doctor --json')
    rows = JSON.parse(out)
    rows = rows['checks'] if rows.is_a?(Hash)
    names = rows.select { |r| r['name'].start_with?('secrets') }
    ok = names.any? { |r| r['name'] == 'secrets backend' && r['status'] == 'ok' } &&
         names.any? { |r| r['name'] == 'secrets store' && r['status'] == 'ok' }
    check('doctor rows wrong', ok, names.inspect)
  end

  def test_tamper_warns_and_continues
    print 'Test 21: tampered store: one warning, shell starts without secrets... '
    saved = File.read(store)
    doc = JSON.parse(saved)
    blob = doc['values']['FAKE_TOKEN']
    doc['values']['FAKE_TOKEN'] = (blob[0] == 'A' ? 'B' : 'A') + blob[1..]
    File.write(store, JSON.pretty_generate(doc))
    out, err, st = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- \"[${FAKE_TOKEN-unset}] $EDITOR\""])
    _, derr, dst = w('const get FAKE_TOKEN')
    dout, = w('doctor')
    File.write(store, saved)
    ok = st.success? && out == "[unset] nvim\n" && err.scan('secrets not loaded').size == 1 &&
         dst.exitstatus == 78 && derr.include?('tampered') && dout.include?('do not decrypt')
    check('tamper not handled', ok, "out=#{out.inspect} err=#{err.inspect}")
  end

  def test_missing_key_never_replaced
    print 'Test 22: missing key with stored secrets: error, no new key... '
    FileUtils.mv(keyfile, "#{keyfile}.saved")
    _, err, st = w('const add FAKE_NEW fake-new-0006 --secret')
    _, gerr, gst = w('const get FAKE_TOKEN')
    created = File.exist?(keyfile)
    FileUtils.mv("#{keyfile}.saved", keyfile)
    check('key regenerated', st.exitstatus == 78 && gst.exitstatus == 78 && !created && err.include?('refusing'), err + gerr)
  end

  def test_unsafe_key_file_refused
    print 'Test 23: group-readable key file is refused... '
    File.chmod(0o640, keyfile)
    _, err, st = w('const get FAKE_TOKEN')
    File.chmod(0o600, keyfile)
    check('unsafe key used', st.exitstatus == 78 && err.include?('group/other'), err)
  end

  def test_bad_backend_rejected
    print 'Test 24: unknown [secrets] backend: validate 65, get 78... '
    path = "#{@config_dir}/wayu.toml"
    saved = File.read(path)
    File.write(path, saved.sub('backend = "file"', 'backend = "vault"'))
    _, _, vst = w('toml validate')
    _, err, gst = w('const get FAKE_TOKEN')
    File.write(path, saved)
    check('bogus backend accepted', vst.exitstatus == 65 && gst.exitstatus == 78 && err.include?('vault'), err)
  end

  def test_remove
    print 'Test 25: const rm removes a secret... '
    _, err, st = w('const rm FAKE_TOKEN')
    out, = w('secrets list')
    _, _, gst = w('const get FAKE_TOKEN')
    check('not removed', st.success? && !out.include?('FAKE_TOKEN') && gst.exitstatus != 0, err)
  end
end

SecretsStoreIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
