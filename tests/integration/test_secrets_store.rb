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
      test_loader_after_path_absolute_bin
      test_bash_sources_cache
      test_fish_sources_cache
      test_stdin_value
      test_hidden_input_signals
      test_convert_plain_constant
      test_convert_scrubs_unicode_cr_del
      test_plain_add_over_secret_refused
      test_add_rolls_back_store_when_entries_fail
      test_dry_run_writes_nothing
      test_secret_flag_rejected_elsewhere
      test_export_eval_has_no_plaintext
      test_rekey
      test_rekey_crash_recovery
      test_lock
      test_cache_symlinks_refused
      test_cache_private_fallback
      test_doctor_ok
      test_tamper_warns_and_continues
      test_missing_key_never_replaced
      test_legacy_keychain_key_moved
      test_unsafe_key_file_refused
      test_bad_backend_rejected
      test_remove
      test_run_only_add
      test_run_only_never_exported
      test_run_only_aad_bound
      test_secrets_run_passes_vars
      test_secrets_run_exit_status
      test_secrets_run_exec_failures
      test_secrets_run_usage
      test_secrets_run_dry_run
      test_run_only_convert
      test_restore_keeps_entries_and_secrets_paired
      test_marker_without_ciphertext_is_an_error
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
    # OKAMI-356: the same source string as the text view and docs/cli.md.
    full, = w('const list --full --no-color')
    text_row = full.lines.find { |l| l.include?('FAKE_TOKEN') }.to_s
    check('json row wrong', row && row['secret'] == true && !row.key?('value') &&
          row['source'] == 'wayu (secret, inactive)' && text_row.include?('wayu (secret, inactive)'),
          "#{out}\n#{text_row}")
    test_search_secret_flag
  end

  # OKAMI-337: search --json flags an encrypted constant, never a value.
  def test_search_secret_flag
    print 'Test 5b: search --json: secret constant has "secret": true, empty value... '
    out, = w('search FAKE_TOKEN --json')
    row = (JSON.parse(out)['results'].find { |r| r['name'] == 'FAKE_TOKEN' } rescue nil)
    text, = w('search FAKE_TOKEN --no-color')
    check('search row wrong', row && row['secret'] == true && row['value'] == '' &&
          !out.include?('fake-tok') && text.include?('********') && !text.include?('fake-tok'),
          out + text)
  end

  def test_get_decrypts
    print 'Test 6: const get decrypts... '
    out, err, st = w('const get FAKE_TOKEN')
    out2, = w('const get FAKE_MULTI')
    check('get wrong', st.success? && out.chomp == TOKEN && out2.chomp == MULTI, err)
  end

  def test_secrets_list_names
    print 'Test 7: secrets list prints names and mode only... '
    out, = w('secrets list')
    check('list wrong', out.split("\n").map(&:split) == [%w[FAKE_MULTI session], %w[FAKE_TOKEN session]], out)
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

  # OKAMI-292: core generated by a wayu found on PATH (argv[0] "wayu") still
  # embeds an absolute path for the cache-miss `secrets cache` call, and the
  # loader runs after the PATH apply: a shell with a minimal PATH loads the
  # secrets.
  def test_loader_after_path_absolute_bin
    print 'Test 9b: secrets loader after PATH, absolute wayu path (bare argv[0])... '
    lbin = "#{@tmp_home}/lbin"
    FileUtils.mkdir_p(lbin)
    FileUtils.cp(@wayu_bin, "#{lbin}/wayu")
    _, err, st = Open3.capture3(env.merge('PATH' => "#{lbin}:/usr/bin:/bin"), 'wayu', 'build', unsetenv_others: true)
    core = File.read("#{@data_dir}/core.zsh")
    sec = core.index('# === Secrets')
    apply = core.index("\n\\_wayu_paths_apply ")
    caches.each { |f| File.delete(f) }
    out, err2, = Open3.capture3(env.merge('PATH' => '/usr/bin:/bin'), 'zsh', '-fc',
                                "source #{@data_dir}/init.zsh; print -r -- \"$FAKE_TOKEN\"", unsetenv_others: true)
    ok = st.success? && sec && apply && apply < sec && core.include?("'#{lbin}/wayu' secrets cache") &&
         out.chomp == TOKEN
    check('loader order/bin', ok, "core=#{core.lines.grep(/secrets cache/).inspect} build=#{err} out=#{out.inspect} err=#{err2} sec=#{sec} apply=#{apply}")
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
    leaked = Dir.glob("#{@data_dir}/backup/*").select { |f| File.file?(f) && File.binread(f).include?('fake-plain-0004') }
    check('plaintext left in backups', leaked.empty?, leaked.inspect)
  end

  def test_convert_scrubs_unicode_cr_del
    print 'Test 13b: conversion scrubs backups of non-Latin-1 / CR / DEL values (OKAMI-296)... '
    leaks = []
    ["fake-pässwörd€xyz", "fake-cr\rx", "fake-del\x7fx"].each_with_index do |plain, i|
      name = "FAKE_SCRUB_#{i}"
      w(['const', 'add', name, plain])
      w(['alias', 'add', "scrub#{i}", 'true'])
      _, err, st = w(['const', 'add', name, '--secret'], stdin: "#{plain}\n")
      leaks << "#{name}: add failed #{err}" unless st.success?
      Dir.glob("#{@data_dir}/backup/**/*").select { |f| File.file?(f) }.each do |f|
        raw = File.binread(f)
        hit = raw.include?(plain.b) || json_strings(raw).any? { |s| s.include?(plain) }
        leaks << "#{name}: #{f}" if hit
      end
    end
    check('plaintext left in backups', leaks.empty?, leaks.join(' '))
  end

  # Every string (keys and values) of a JSON document; [] when it does not parse.
  def json_strings(raw)
    walk = lambda do |v|
      case v
      when String then [v]
      when Array then v.flat_map(&walk)
      when Hash then v.flat_map { |k, x| [k] + walk.call(x) }
      else []
      end
    end
    walk.call(JSON.parse(raw.dup.force_encoding('UTF-8')))
  rescue JSON::ParserError, EncodingError
    []
  end

  # Echo state of a terminal: true / false (from `stty -a`).
  def tty_echo?(tty)
    out = `stty -a < #{tty} 2>/dev/null`
    out.match?(/(?<![-\w])echo(?!\w)/)
  end

  def read_until(io, pattern, timeout = 10)
    buf = +''
    deadline = Time.now + timeout
    until buf.match?(pattern) || Time.now > deadline
      begin
        buf << io.read_nonblock(4096)
      rescue IO::WaitReadable
        IO.select([io], nil, nil, 0.1)
      rescue EOFError, Errno::EIO
        break
      end
    end
    buf
  end

  # Write to a pty whose other side may already be gone.
  def pty_write(io, text)
    io.write(text)
  rescue Errno::EIO, IOError
    nil
  end

  # Ctrl-Z / Ctrl-C at the hidden value prompt, on a real terminal. The
  # fixtures/jobctl.py parent puts wayu in its own foreground process group
  # (a group that can stop) and reports the echo state when it stops / exits.
  def test_hidden_input_signals
    print 'Test 12b: Ctrl-Z / Ctrl-C at the hidden prompt restore echo (OKAMI-324)... '
    if `command -v python3 2>/dev/null`.strip.empty?
      puts 'skipped (python3 not installed)'
      return
    end
    require 'pty'
    jobctl = File.join(__dir__, 'fixtures', 'jobctl.py')
    r, wr, pid = PTY.spawn(env, 'python3', jobctl, @wayu_bin, 'const', 'add', 'FAKE_SIG', '--secret')
    out = read_until(r, /input hidden/)
    tty = out[/TTY (\S+)/, 1]
    pty_write(wr, "\x1a") # Ctrl-Z
    stopped = read_until(r, /STOPPED echo-\w+/)[/STOPPED (echo-\w+)/, 1]
    pty_write(wr, "\n") # jobctl: continue it
    sleep 0.5
    resumed_echo = tty && tty_echo?(tty)
    pty_write(wr, "\x03") # Ctrl-C
    exited = read_until(r, /EXITED echo-\w+/)[/EXITED (echo-\w+)/, 1]
    _, _, gst = w('const get FAKE_SIG')
    ok = stopped == 'echo-on' && resumed_echo == false && exited == 'echo-on' && !gst.success?
    check('echo left off', ok,
          "stopped=#{stopped.inspect} resumed_echo=#{resumed_echo.inspect} exited=#{exited.inspect} get=#{gst.exitstatus}")
  ensure
    begin
      if pid
        Process.kill('KILL', pid)
        Process.wait(pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_plain_add_over_secret_refused
    print 'Test 14: plain add over a secret is refused (65)... '
    _, err, st = w('const add FAKE_TOKEN plain')
    check('plain add accepted', st.exitstatus == 65 && err.include?('encrypted secret'), err)
  end

  def test_add_rolls_back_store_when_entries_fail
    print 'Test 14b: entries.json write fails: secrets.json rolled back (OKAMI-323)... '
    entries = "#{@data_dir}/entries.json"
    saved = File.read(entries)
    before = File.read(store)
    File.write(entries, '{"version": 1, "env": [')
    _, err, st = w(['const', 'add', 'FAKE_ROLLBACK', 'fake-rollback-0009', '--secret'])
    after = File.read(store)
    File.write(entries, saved)
    listed, = w('secrets list')
    ok = !st.success? && after == before && !listed.include?('FAKE_ROLLBACK')
    check('secret kept without its entries.json marker', ok, "#{st.exitstatus} #{err}")
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

  def test_rekey_crash_recovery
    print 'Test 18b: an interrupted rekey is finished or undone on the next load (OKAMI-302)... '
    s1 = File.read(store)
    k1 = File.read(keyfile)
    _, err, st = w('secrets rekey')
    s2 = File.read(store)
    pending = "#{store}.rekey"
    # Crash after the new key was saved, before the rename: finish it.
    File.write(pending, s2, perm: 0o600)
    File.write(store, s1)
    out_a, err_a, st_a = w('const get FAKE_TOKEN')
    a_ok = st_a.success? && out_a.chomp == TOKEN && !File.exist?(pending) && File.read(store) == s2
    # Crash before the key was saved: drop the pending store.
    File.write(keyfile, k1)
    File.write(store, s1)
    File.write(pending, s2, perm: 0o600)
    out_b, err_b, st_b = w('const get FAKE_TOKEN')
    b_ok = st_b.success? && out_b.chomp == TOKEN && !File.exist?(pending) && File.read(store) == s1
    check('rekey not recovered', st.success? && a_ok && b_ok, "#{err} a=#{a_ok} #{err_a} b=#{b_ok} #{err_b}")
  end

  def test_lock
    print 'Test 19: lock deletes the session cache... '
    sh(['zsh', '-fc', "source #{@data_dir}/init.zsh"])
    had = caches.any?
    _, err, st = w('secrets lock')
    check('cache kept', had && st.success? && caches.empty?, err)
  end

  PLANTED = "export FAKE_TOKEN=planted; export FAKE_PLANTED=1\n".freeze

  def zsh_secret_probe(extra_env = {})
    out, err, = Open3.capture3(env.merge(extra_env), 'zsh', '-fc',
                               "source #{@data_dir}/init.zsh; print -r -- \"[${FAKE_PLANTED-unset}] $FAKE_TOKEN\"",
                               unsetenv_others: true)
    [out.force_encoding('UTF-8'), err]
  end

  def test_cache_symlinks_refused
    print 'Test 19b: a symlinked cache file or cache dir is never sourced (OKAMI-300)... '
    w('secrets lock')
    elsewhere = "#{@tmp_home}/elsewhere"
    FileUtils.mkdir_p(elsewhere, mode: 0o700)
    # (a) the cache file is a symlink to a newer file we own.
    sh(['zsh', '-fc', "source #{@data_dir}/init.zsh"])
    cache = caches.find { |f| f.end_with?('.zsh') }
    File.write("#{elsewhere}/planted.zsh", PLANTED)
    File.delete(cache)
    File.symlink("#{elsewhere}/planted.zsh", cache)
    future = Time.now + 3600
    File.utime(future, future, "#{elsewhere}/planted.zsh")
    out_a, err_a = zsh_secret_probe
    # (b) the cache dir is a symlink to a dir holding a fresh planted cache.
    FileUtils.rm_rf(cache_dir)
    File.symlink(elsewhere, cache_dir)
    File.write("#{elsewhere}/#{File.basename(cache)}", PLANTED)
    File.utime(future, future, "#{elsewhere}/#{File.basename(cache)}")
    out_b, err_b = zsh_secret_probe
    private_cache = Dir.glob("#{@data_dir}/run/wayu-#{Process.uid}/secrets-*.zsh")
    File.delete(cache_dir)
    FileUtils.rm_rf(elsewhere)
    ok = out_a == "[unset] #{TOKEN}\n" && out_b == "[unset] #{TOKEN}\n" && private_cache.size == 1 &&
         mode(File.dirname(private_cache[0])) == 0o700
    check('planted cache sourced', ok, "a=#{out_a.inspect} #{err_a} b=#{out_b.inspect} #{err_b} private=#{private_cache}")
  end

  def test_cache_private_fallback
    print 'Test 19c: no XDG_RUNTIME_DIR / TMPDIR: cache in <data>/run, never /tmp (OKAMI-300)... '
    FileUtils.rm_rf("#{@data_dir}/run")
    no_tmp = env.reject { |k, _| k == 'TMPDIR' }
    out, err, = Open3.capture3(no_tmp, 'zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- \"$FAKE_TOKEN\"",
                               unsetenv_others: true)
    files = Dir.glob("#{@data_dir}/run/wayu-#{Process.uid}/secrets-*.zsh")
    in_tmp = File.exist?("/tmp/wayu-#{Process.uid}") && Dir.glob("/tmp/wayu-#{Process.uid}/secrets-*").any? { |f| File.mtime(f) > Time.now - 30 }
    ok = out.force_encoding('UTF-8') == "#{TOKEN}\n" && files.size == 1 && mode(files[0]) == 0o600 &&
         mode("#{@data_dir}/run") == 0o700 && !in_tmp
    check('cache not in the private dir', ok, "out=#{out.inspect} err=#{err} files=#{files}")
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

  # A fake `security` on PATH: items are files <dir>/<account> (never the
  # real keychain). find-generic-password exits 44 when there is no item.
  def fake_security(dir)
    FileUtils.mkdir_p("#{dir}/bin")
    File.write("#{dir}/bin/security", <<~SH)
      #!/bin/sh
      cmd=$1; shift; acct=; pw=
      while [ $# -gt 0 ]; do
        case $1 in -a) acct=$2; shift ;; -w) [ $# -gt 1 ] && { pw=$2; shift; } ;; -s|-l) shift ;; esac
        shift
      done
      case $cmd in
        find-generic-password) [ -f "#{dir}/$acct" ] || exit 44; cat "#{dir}/$acct" ;;
        add-generic-password) printf '%s' "$pw" > "#{dir}/$acct" ;;
        *) exit 1 ;;
      esac
    SH
    File.chmod(0o755, "#{dir}/bin/security")
  end

  # OKAMI-306 follow-up: a 6.0 key (keychain account "wayu") is moved to the
  # per-data-dir account when it decrypts secrets.json, never otherwise.
  def test_legacy_keychain_key_moved
    print 'Test 22b: wayu 6.0 keychain key moved to the per-data-dir account... '
    kc = "#{@tmp_home}/fake-keychain"
    fake_security(kc)
    path = "#{@config_dir}/wayu.toml"
    saved = File.read(path)
    File.write(path, saved.sub('backend = "file"', 'backend = "keychain"'))
    kenv = env.merge('PATH' => "#{kc}/bin:#{ENV['PATH']}")
    get = lambda do
      out, err, st = Open3.capture3(kenv, @wayu_bin, 'const', 'get', 'FAKE_TOKEN', unsetenv_others: true)
      [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
    end
    new_items = -> { Dir.children(kc).reject { |n| %w[bin wayu].include?(n) } }
    # A 6.0 key that does not decrypt the store: left alone, key still missing.
    File.write("#{kc}/wayu", 'ab' * 32)
    _, werr, wst = get.call
    wrong_ok = wst.exitstatus == 78 && new_items.call.empty? && werr.include?('missing')
    # The right 6.0 key: moved, value decrypts, notice once, old item kept.
    File.write("#{kc}/wayu", File.read(keyfile).strip)
    out, err, st = get.call
    moved = new_items.call
    out2, err2, st2 = get.call
    File.write(path, saved)
    ok = wrong_ok && st.success? && out.chomp == TOKEN && err.include?('moved the master key') &&
         err.include?('security delete-generic-password -a wayu') &&
         moved.size == 1 && moved[0].match?(/\Awayu-\h{16}\z/) &&
         File.read("#{kc}/#{moved[0]}") == File.read(keyfile).strip && File.exist?("#{kc}/wayu") &&
         st2.success? && out2.chomp == TOKEN && !err2.include?('moved')
    check('6.0 key not moved correctly', ok, "wrong=#{wrong_ok} #{werr} | #{st.exitstatus} #{err} | #{moved.inspect} | #{err2}")
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

  RUN_ONLY = 'fake-run-only-0007'.freeze

  def test_run_only_add
    print 'Test 26: const add --run-only: marked in secrets.json, entries.json, list... '
    _, err, st = w(['const', 'add', 'FAKE_RUN', RUN_ONLY, '--run-only'])
    doc = JSON.parse(File.read(store))
    marker = JSON.parse(File.read("#{@data_dir}/entries.json"))['env'].find { |e| e['name'] == 'FAKE_RUN' }
    row = JSON.parse(w('const list --json')[0])['constants'].find { |c| c['constant'] == 'FAKE_RUN' }
    text, = w('const list')
    listed, = w('secrets list')
    ok = st.success? && doc['run_only'] == ['FAKE_RUN'] &&
         marker == { 'name' => 'FAKE_RUN', 'secret' => true, 'run_only' => true } &&
         row && row['run_only'] == true && row['secret'] == true && !row.key?('value') && row['source'] == 'wayu (run-only)' &&
         text.include?('wayu (run-only)') && listed.split("\n").map(&:split).include?(%w[FAKE_RUN run-only])
    check('run-only not recorded', ok, err + listed)
  end

  def test_run_only_never_exported
    print 'Test 27: run-only value never in cache, core, turbo, export --eval... '
    w('export turbo')
    out, = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- \"[${FAKE_RUN-unset}] $FAKE_MULTI\""])
    eval_out, = w('export --eval')
    files = caches + Dir.glob("#{@data_dir}/{core,turbo}.*")
    # A background zcompile's temp file can vanish between glob and read.
    read = lambda do |f|
      File.binread(f)
    rescue Errno::ENOENT
      ''
    end
    leaks = files.select { |f| s = read.call(f); s.include?('FAKE_RUN') || s.include?('fake-run-only') }
    ok = out.start_with?('[unset] fake-line-1') && caches.any? && leaks.empty? && !eval_out.include?('fake-run-only')
    check('run-only leaked', ok, "out=#{out.inspect} leaks=#{leaks}")
  end

  def test_run_only_aad_bound
    print 'Test 28: editing run_only away does not export it (AAD-bound)... '
    saved = File.read(store)
    doc = JSON.parse(saved)
    doc.delete('run_only')
    File.write(store, JSON.pretty_generate(doc))
    _, err, st = w('secrets cache --shell zsh')
    leaked = caches.any? { |f| File.binread(f).include?('fake-run-only') }
    File.write(store, saved)
    w('secrets lock')
    check('flag edit exported the value', !st.success? && err.include?('FAKE_RUN') && !leaked, err)
  end

  def test_secrets_run_passes_vars
    print 'Test 29: secrets run sets run-only and session secrets in the child only... '
    _, err, st = w(['secrets', 'run', 'FAKE_RUN', 'FAKE_MULTI', '--', 'sh', '-c',
                    "test \"$FAKE_RUN\" = '#{RUN_ONLY}' && test \"$FAKE_MULTI\" = \"$(printf 'fake-line-1\\nfake-line-2')\""])
    _, _, st2 = w(['secrets', 'run', 'FAKE_RUN', '--', 'sh', '-c', 'test "$FAKE_RUN" = wrong'])
    check('child did not get the values', st.success? && st2.exitstatus == 1, err)
  end

  def test_secrets_run_exit_status
    print 'Test 30: secrets run passes the exit status through... '
    _, _, st = w(['secrets', 'run', 'FAKE_RUN', '--', 'sh', '-c', 'exit 7'])
    check('exit status lost', st.exitstatus == 7, st.inspect)
  end

  def test_secrets_run_exec_failures
    print 'Test 31: secrets run: 127 not found, 126 not executable... '
    noexec = "#{@tmp_home}/noexec.sh"
    File.write(noexec, "#!/bin/sh\nexit 0\n")
    File.chmod(0o644, noexec)
    _, err1, st1 = w(['secrets', 'run', 'FAKE_RUN', '--', 'wayu-no-such-command-xyz'])
    _, err2, st2 = w(['secrets', 'run', 'FAKE_RUN', '--', noexec])
    ok = st1.exitstatus == 127 && st2.exitstatus == 126 && !(err1 + err2).include?('fake-run-only')
    check('exec failure codes wrong', ok, "#{st1.exitstatus} #{st2.exitstatus} #{err1}#{err2}")
  end

  def test_secrets_run_usage
    print 'Test 32: secrets run usage: no -- or no CMD 64, unknown name 65... '
    _, _, a = w(['secrets', 'run', 'FAKE_RUN', 'true'])
    _, _, b = w(['secrets', 'run', 'FAKE_RUN', '--'])
    _, _, c = w(['secrets', 'run', '--', 'true'])
    _, _, d = w(['secrets', 'run', 'NO_SUCH_SECRET', '--', 'true'])
    codes = [a, b, c, d].map(&:exitstatus)
    check('usage codes wrong', codes == [64, 64, 64, 65], codes.inspect)
  end

  def test_secrets_run_dry_run
    print 'Test 33: secrets run --dry-run names the vars, runs nothing, no values... '
    marker = "#{@tmp_home}/ran"
    out, err, st = w(['secrets', 'run', 'FAKE_RUN', '--dry-run', '--', 'touch', marker])
    ok = st.success? && !File.exist?(marker) && out.include?('FAKE_RUN') && out.include?('touch') && !(out + err).include?('fake-run-only')
    check('dry-run wrong', ok, out + err)
  end

  def test_run_only_convert
    print 'Test 34: re-adding with --secret makes it a session secret, and back... '
    w(['const', 'add', 'FAKE_RUN', RUN_ONLY, '--secret'])
    out, = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; [[ $FAKE_RUN == '#{RUN_ONLY}' ]] && print ok"])
    doc1 = JSON.parse(File.read(store))
    w(['const', 'add', 'FAKE_RUN', RUN_ONLY, '--run-only'])
    out2, = sh(['zsh', '-fc', "source #{@data_dir}/init.zsh; print -r -- ${FAKE_RUN-unset}"])
    got, = w('const get FAKE_RUN')
    ok = out == "ok\n" && !doc1.key?('run_only') && out2 == "unset\n" && got.chomp == RUN_ONLY
    check('conversion wrong', ok, "#{out.inspect} #{out2.inspect}")
  end

  def doctor_rows
    out, = w('doctor --json')
    rows = JSON.parse(out)
    rows.is_a?(Hash) ? rows['checks'] : rows
  end

  def test_restore_keeps_entries_and_secrets_paired
    print 'Test 35: backup restore of entries.json restores secrets.json with it (OKAMI-303)... '
    _, err, st = w(['const', 'add', 'FAKE_BK', 'fake-bk-0010', '--secret'])
    _, rerr, rst = w('backup restore entries --yes')
    gone = !w('secrets list')[0].include?('FAKE_BK') &&
           JSON.parse(File.read("#{@data_dir}/entries.json"))['env'].none? { |e| e['name'] == 'FAKE_BK' }
    _, uerr, ust = w('backup restore entries 1 --yes') # undo: the pre-restore snapshot
    back, = w('const get FAKE_BK')
    ok = st.success? && rst.success? && gone && ust.success? && back.chomp == 'fake-bk-0010'
    check('entries.json and secrets.json restored apart', ok, "#{err}#{rerr}#{uerr} gone=#{gone} back=#{back.inspect}")
  end

  def test_marker_without_ciphertext_is_an_error
    print 'Test 36: secret marker without ciphertext: get 65, doctor error; orphan ciphertext: warning... '
    saved = File.read(store)
    doc = JSON.parse(saved)
    doc['values'].delete('FAKE_BK')
    File.write(store, JSON.pretty_generate(doc))
    out, err, st = w('const get FAKE_BK')
    rows = doctor_rows
    _, _, dst = w('doctor')
    missing = rows.find { |r| r['name'] == 'secrets pairing' && r['status'] == 'error' }
    File.write(store, saved)
    entries = "#{@data_dir}/entries.json"
    saved_entries = File.read(entries)
    edoc = JSON.parse(saved_entries)
    edoc['env'].reject! { |e| e['name'] == 'FAKE_BK' }
    File.write(entries, JSON.pretty_generate(edoc))
    orphan = doctor_rows.find { |r| r['name'] == 'secrets pairing' && r['status'] == 'warning' }
    File.write(entries, saved_entries)
    ok = st.exitstatus == 65 && out.empty? && err.include?('FAKE_BK') && missing && missing['message'].include?('FAKE_BK') &&
         dst.exitstatus == 78 && orphan && orphan['message'].include?('FAKE_BK')
    check('inconsistency not reported', ok, "get=#{st.exitstatus} #{err} doctor=#{dst.exitstatus} #{missing.inspect} #{orphan.inspect}")
  end
end

SecretsStoreIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
