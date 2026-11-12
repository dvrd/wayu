#!/usr/bin/env ruby
# Integration tests for multi-machine secrets (OKAMI-370, experimental):
# machines are temporary HOMEs (A, B, ...) with `[secrets] backend = "file"`
# and their own TMPDIR; "syncing" copies secrets.json + entries.json from one
# data dir to the other. The real keychain, HOME and /tmp are never touched
# (the keychain case uses a fake `security` through a WAYU_TEST_KEYSTORE
# build). Every value and key here is fake.

require 'open3'
require 'json'
require 'fileutils'
require 'socket'
require_relative 'test_helper'

class SecretsMultiIntegrationTest
  include WayuTestHelper

  FIXTURE = File.expand_path('fixtures/secrets-v1', __dir__)
  PASS = 'fake recovery passphrase 0001'.freeze

  def initialize
    setup_test_env
    @machines = {}
  end

  def run
    puts '🔐 Testing multi-machine secrets...'
    puts

    begin
      build_project
      %w[A B C D E].each { |m| machine(m) }

      test_v1_untouched_until_opt_in
      test_dry_run_writes_nothing
      test_experimental_notice_once
      test_add_migrates_with_backup_and_notice
      test_second_machine_reads
      test_shell_start_adopts_once
      test_recipient_list_json
      test_add_errors
      test_rename
      test_rekey_adopted_with_proof
      test_rm_rotates_removed_machine_locked_out
      test_attacker_store_refused_then_adopt
      test_concurrent_rekey_doctor_error
      test_recovery_unlock
      test_fixture_migration_and_restore_rewrap
      test_doctor_v2_rows
      test_doctor_git_and_conflict_warnings
      test_keychain_identity_off_argv
      test_downgrade_to_v1_refused
      test_rm_drops_tampered_entry_first
      test_broken_own_stanza_guidance
      test_removed_recipient_back_not_adopted
      test_rollback_refused_not_adoptable
      test_recovery_rm_note_and_params
      test_wording
    ensure
      teardown_test_env
    end

    print_summary('multi-machine secrets')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # A machine: its own HOME and TMPDIR, initialized, file backend.
  def machine(name)
    return @machines[name] if @machines[name]
    home = "#{@tmp_home}/m#{name}"
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/.local/share", "#{home}/rt"])
    m = { home: home, config: "#{home}/.config/wayu", data: "#{home}/.local/share/wayu", rt: "#{home}/rt" }
    @machines[name] = m
    _, err, st = w(name, 'init --shell zsh')
    raise "init #{name} failed: #{err}" unless st.success?
    File.open("#{m[:config]}/wayu.toml", 'a') { |f| f.puts "\n[secrets]\nbackend = \"file\"" }
    m
  end

  def env_for(name, extra = {})
    m = @machines[name]
    { 'HOME' => m[:home], 'PATH' => ENV['PATH'], 'SHELL' => '/bin/zsh', 'NO_COLOR' => '1',
      'TMPDIR' => "#{m[:rt]}/" }.merge(sanitizer_env).merge(extra)
  end

  def w(name, args, stdin: nil, bin: nil, extra: {})
    argv = args.is_a?(Array) ? args : args.split(' ')
    out, err, st = Open3.capture3(env_for(name, extra), bin || @wayu_bin, *argv,
                                  stdin_data: stdin || '', unsetenv_others: true)
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

  def store(name)
    "#{@machines[name][:data]}/secrets.json"
  end

  def keyfile(name)
    "#{@machines[name][:config]}/secret.key"
  end

  def idfile(name)
    "#{@machines[name][:config]}/identity.key"
  end

  def doc(name)
    JSON.parse(File.read(store(name)))
  end

  # Copy the synced pair from one machine to another.
  def sync(from, to)
    %w[secrets.json entries.json].each do |f|
      FileUtils.cp("#{@machines[from][:data]}/#{f}", "#{@machines[to][:data]}/#{f}")
    end
  end

  def get(name, var)
    out, err, st = w(name, "const get #{var}")
    [out.chomp, err, st]
  end

  # wayu's default recipient name for this host, nil when the hostname gives
  # none (empty or an IP address: wayu then asks for --name).
  def host_name
    full = Socket.gethostname.to_s
    return nil if full.empty? || full.include?(':') || full.match?(/\A[0-9.]+\z/)
    h = full.split('.').first.to_s.gsub(/[^A-Za-z0-9._-]/, '-')[0, 64]
    h.empty? ? nil : h
  end

  # The name a machine has as a recipient of its own store.
  def self_name(name)
    host_name || "self#{name.downcase}"
  end

  # First recipient add on a version 1 store (the upgrade). With a hostname
  # that gives no default name, this machine is added by name first.
  def first_add(name, rcp, as, bin: nil, extra: {})
    errs = ''
    if host_name.nil?
      _, e, st = w(name, ['secrets', 'recipient', 'add', recipient(name, bin: bin, extra: extra), '--name', self_name(name)],
                   bin: bin, extra: extra)
      raise "self add #{name}: #{e}" unless st.success?
      errs += e
    end
    out, e, st = w(name, ['secrets', 'recipient', 'add', rcp, '--name', as], bin: bin, extra: extra)
    [out, errs + e, st]
  end

  # The fingerprint a command printed ("data key fingerprint: …").
  def fingerprint(out)
    out[/data key fingerprint: (\h{16})/, 1]
  end

  def recipient(name, bin: nil, extra: {})
    out, err, st = w(name, 'secrets identity', bin: bin, extra: extra)
    raise "identity #{name}: #{err}" unless st.success?
    out.strip
  end

  def doctor_rows(name)
    out, = w(name, 'doctor --json')
    JSON.parse(out)['checks']
  rescue JSON::ParserError
    []
  end

  def entries_backups(name)
    Dir.glob("#{@machines[name][:data]}/backup/entries.json.*").reject { |f| f.include?('/secrets/') }
  end

  def companions(name)
    Dir.glob("#{@machines[name][:data]}/backup/secrets/*")
  end

  # ---------------------------------------------------------------------

  def test_v1_untouched_until_opt_in
    print 'Test 1: v1 store stays v1: identity and list do not rewrite it... '
    _, err, st = w('A', ['const', 'add', 'FAKE_A1', 'fake-a1-0001', '--secret'])
    before = File.binread(store('A'))
    out, ierr, ist = w('A', 'secrets identity')
    lout, _, lst = w('A', 'secrets recipient list')
    jout, _, jst = w('A', 'secrets recipient list --json')
    j = JSON.parse(jout) rescue {}
    ok = st.success? && ist.success? && out.strip.start_with?('age1') && lst.success? && jst.success? &&
         File.binread(store('A')) == before && doc('A')['version'] == 1 &&
         lout.include?('version 1') && j == { 'recipients' => [], 'key_id' => '', 'recovery' => false } &&
         ierr.include?("wayu secrets recipient add #{out.strip} --name #{host_name || 'NAME'}") &&
         (File.stat(idfile('A')).mode & 0o777) == 0o600 &&
         File.read(idfile('A')).include?("# public key: #{out.strip}")
    check('v1 store changed or identity wrong', ok, "#{err}#{ierr} #{lout} #{jout}")
  end

  def test_dry_run_writes_nothing
    print 'Test 2: --dry-run writes nothing (store, identity, backups, notice marker)... '
    rb_dir = @machines['B'][:config]
    _, err, st = w('B', 'secrets identity --dry-run')
    no_id = !File.exist?(idfile('B'))
    marker = Dir.glob("#{@machines['B'][:data]}/run/notice-*").empty?
    fake = recipient('C')
    before = File.binread(store('A'))
    nb = entries_backups('A').size
    out, aerr, ast = if host_name
                       w('A', "secrets recipient add #{fake} --name boxc --dry-run")
                     else
                       w('A', "secrets recipient add #{recipient('A')} --name #{self_name('A')} --dry-run")
                     end
    ok = st.success? && no_id && marker && !Dir.exist?("#{rb_dir}/identity.key") && ast.success? &&
         out.include?('[dry-run]') && out.include?('version 2') && File.binread(store('A')) == before &&
         entries_backups('A').size == nb && err.include?('experimental')
    check('dry-run wrote something', ok, "#{err} #{out} #{aerr}")
  end

  def test_experimental_notice_once
    print 'Test 3: experimental notice on the first multi-machine command only... '
    _, e1, = w('D', 'secrets recipient list')
    _, e2, = w('D', 'secrets recipient list')
    ok = e1.include?('multi-machine secrets are experimental') && !e2.include?('experimental')
    check('notice not once', ok, "#{e1.inspect} #{e2.inspect}")
  end

  def test_add_migrates_with_backup_and_notice
    print 'Test 4: first recipient add: v1 -> v2, backup, verify, notice, value lines unchanged... '
    @rb = recipient('B')
    v1 = File.read(store('A'))
    nb = entries_backups('A').size
    guard = true
    if host_name.nil?
      # An IP hostname gives no name for this machine: 64, nothing written.
      _, gerr, gst = w('A', "secrets recipient add #{@rb} --name boxb")
      guard = gst.exitstatus == 64 && gerr.include?('--name NAME') && File.read(store('A')) == v1
    end
    @add_out, err, st = first_add('A', @rb, 'boxb')
    d = doc('A')
    v2 = File.read(store('A'))
    value_lines = v1.lines.select { |l| l.start_with?('    "FAKE_') }
    comp = companions('A').map { |f| File.read(f) }
    nb_after = entries_backups('A').size - (host_name ? 0 : 1)
    _, err2, st2 = w('A', ['const', 'add', 'FAKE_A2', 'fake-a2-0002', '--secret'])
    ok = guard && st.success? && d['version'] == 2 && d['recipients'].map { |r| r['name'] }.sort == ['boxb', self_name('A')].sort &&
         fingerprint(@add_out) == d['key_id'] && @add_out.include?('wayu secrets adopt --yes') &&
         d['recipients'].any? { |r| r['recipient'] == @rb } && d['key_id'].match?(/\A\h{16}\z/) &&
         !value_lines.empty? && value_lines.all? { |l| v2.include?(l) } &&
         nb_after == nb + 1 && comp.include?(v1) &&
         err.include?('is now version 2') && err.include?('wayu 7.0 and older cannot read it') &&
         st2.success? && !err2.include?('version 2')
    check('migration wrong', ok, "#{err} #{d.inspect[0, 300]}")
  end

  def test_second_machine_reads
    print 'Test 5: B (synced): no trust on first use (78, adopt), adopt --yes shows the same fingerprint, then reads... '
    sync('A', 'B')
    _, ferr, fst = get('B', 'FAKE_A1')
    no_key = !File.exist?(keyfile('B'))
    aout, aerr, ast = w('B', 'secrets adopt --yes')
    out, err, st = get('B', 'FAKE_A1')
    out2, err2, st2 = get('B', 'FAKE_A2')
    ok = fst.exitstatus == 78 && ferr.include?('has not adopted data key') && ferr.include?('wayu secrets adopt --yes') && no_key &&
         ast.success? && fingerprint(aout) == fingerprint(@add_out) && fingerprint(aout) == doc('A')['key_id'] &&
         st.success? && out == 'fake-a1-0001' && !err.include?('adopted') &&
         st2.success? && out2 == 'fake-a2-0002' &&
         File.exist?(keyfile('B')) && (File.stat(keyfile('B')).mode & 0o777) == 0o600
    check('B cannot read', ok, "#{fst.exitstatus} #{ferr} | #{aout} #{aerr} | #{err} | #{err2}")
  end

  def test_shell_start_adopts_once
    print 'Test 6: shell start on a fresh machine: not a recipient; after add: adopt needed (one line); after adopt: values... '
    sync('A', 'E')
    w('E', 'build')
    zsh = lambda do
      Open3.capture3(env_for('E'), 'zsh', '-fc', "source #{@machines['E'][:data]}/init.zsh; print -r -- \"<${FAKE_A1-unset}>\"",
                     unsetenv_others: true)
    end
    out, err, = zsh.call
    not_recipient = out.include?('<unset>') && err.include?('secrets not loaded: this machine is not a recipient') &&
                    err.include?("run 'wayu secrets identity' and add it from a machine that is")
    re = recipient('E')
    w('A', "secrets recipient add #{re} --name boxe")
    sync('A', 'E')
    out2, err2, = zsh.call
    _, _, ast = w('E', 'secrets adopt --yes')
    out3, err3, = zsh.call
    ok = not_recipient && out2.include?('<unset>') && err2.lines.size == 1 &&
         err2.include?('secrets not loaded: this machine has not adopted data key') &&
         err2.include?('wayu secrets adopt --yes') && ast.success? &&
         out3.include?('<fake-a1-0001>') && err3.empty?
    check('shell start wrong', ok, "#{out}#{err} | #{out2}#{err2} | #{out3}#{err3}")
  end

  def test_recipient_list_json
    print 'Test 7: recipient list --json: shape and this_machine... '
    out, _, st = w('B', 'secrets recipient list --json')
    j = JSON.parse(out) rescue {}
    rows = j['recipients'] || []
    ok = st.success? && j.keys.sort == %w[key_id recipients recovery].sort &&
         rows.all? { |r| r.keys.sort == %w[name recipient this_machine].sort } &&
         rows.find { |r| r['this_machine'] }&.dig('name') == 'boxb' && rows.count { |r| r['this_machine'] } == 1 &&
         j['key_id'] == doc('A')['key_id']
    text, = w('B', 'secrets recipient list')
    check('json shape wrong', ok && text.include?('(this machine)') && text.include?('data key:'), out)
  end

  def test_add_errors
    print 'Test 8: add errors: bad 65, age1pq 65 (reserved), duplicate 65, no --name 64, rm/adopt without --yes 64... '
    codes = {}
    codes[:bad] = w('A', 'secrets recipient add age1nope --name x')[2].exitstatus
    _, pqerr, pqst = w('A', 'secrets recipient add age1pq1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq --name x')
    codes[:pq] = pqst.exitstatus
    codes[:dup_name] = w('A', "secrets recipient add #{recipient('C')} --name boxb")[2].exitstatus
    codes[:dup_key] = w('A', "secrets recipient add #{@rb} --name other")[2].exitstatus
    _, nerr, nst = w('A', "secrets recipient add #{recipient('C')}")
    codes[:no_name] = nst.exitstatus
    codes[:bad_name] = w('A', "secrets recipient add #{recipient('C')} --name a/b")[2].exitstatus
    codes[:rm_noyes] = w('A', 'secrets recipient rm boxb')[2].exitstatus
    codes[:rm_unknown] = w('A', 'secrets recipient rm nobody --yes')[2].exitstatus
    codes[:rm_self] = w('A', "secrets recipient rm #{self_name('A')} --yes")[2].exitstatus
    codes[:adopt_noyes] = w('A', 'secrets adopt')[2].exitstatus
    want = { bad: 65, pq: 65, dup_name: 65, dup_key: 65, no_name: 64, bad_name: 65, rm_noyes: 64,
             rm_unknown: 65, rm_self: 65, adopt_noyes: 64 }
    ok = codes == want && pqerr.include?('post-quantum') && nerr.include?('--name NAME is required')
    check('error codes wrong', ok, "#{codes.inspect} #{pqerr} #{nerr}")
  end

  def test_rename
    print 'Test 9: rename: entry renamed, stanza re-derived, B still reads... '
    _, err, st = w('A', 'secrets recipient rename boxb desk')
    names = doc('A')['recipients'].map { |r| r['name'] }
    _, derr, dst = w('A', 'secrets recipient rename desk boxe')
    sync('A', 'B')
    out, gerr, gst = get('B', 'FAKE_A1')
    ok = st.success? && names.include?('desk') && !names.include?('boxb') && dst.exitstatus == 65 &&
         gst.success? && out == 'fake-a1-0001'
    check('rename wrong', ok, "#{err} #{derr} #{gerr}")
  end

  def test_rekey_adopted_with_proof
    print 'Test 10: rekey on A: new key, proof appended; B adopts it (rotation verified)... '
    old = doc('A')['key_id']
    _, err, st = w('A', 'secrets rekey')
    d = doc('A')
    sync('A', 'B')
    out, gerr, gst = get('B', 'FAKE_A2')
    ok = st.success? && d['key_id'] != old && d['rotations'].last['from'] == old && d['rotations'].last['to'] == d['key_id'] &&
         gst.success? && out == 'fake-a2-0002' && gerr.include?("rotation from #{old} verified")
    check('rekey adoption wrong', ok, "#{err} #{gerr}")
  end

  def test_rm_rotates_removed_machine_locked_out
    print 'Test 11: rm --yes rotates; the removed machine cannot read new values, still reads its old copy... '
    old_copy = File.binread(store('B'))
    old_entries = File.binread("#{@machines['B'][:data]}/entries.json")
    old_id = doc('A')['key_id']
    _, err, st = w('A', 'secrets recipient rm desk --yes')
    d = doc('A')
    no_companions = companions('A').empty?
    w('A', ['const', 'add', 'FAKE_NEW', 'fake-new-0003', '--secret'])
    sync('A', 'B')
    _, nerr, nst = get('B', 'FAKE_NEW')
    _, oerr, ost = get('B', 'FAKE_A1')
    File.binwrite(store('B'), old_copy)
    File.binwrite("#{@machines['B'][:data]}/entries.json", old_entries)
    old_out, = get('B', 'FAKE_A1')
    ok = st.success? && d['key_id'] != old_id && !d['recipients'].any? { |r| r['name'] == 'desk' } &&
         d['rotations'].last['from'] == old_id &&
         nst.exitstatus == 78 && nerr.include?('not a recipient') && nerr.include?('wayu secrets recipient add') &&
         ost.exitstatus == 78 && old_out == 'fake-a1-0001' && no_companions
    check('rm wrong', ok, "#{err} | #{nst.exitstatus} #{nerr} | #{ost.exitstatus} #{oerr} | #{old_out}")
    # B rejoins for the later tests.
    w('A', "secrets recipient add #{@rb} --name boxb")
    sync('A', 'B')
  end

  def test_attacker_store_refused_then_adopt
    print 'Test 12: attacker store (fresh key wrapped to A, no proof): 78 + adopt guidance, nothing encrypted; adopt --yes... '
    saved_store = File.binread(store('A'))
    saved_entries = File.binread("#{@machines['A'][:data]}/entries.json")
    saved_key = File.binread(keyfile('A'))
    # Machine C: its own key, its own v1 store, then wrapped to A's recipient.
    w('C', ['const', 'add', 'FAKE_A1', 'attacker-0004', '--secret'])
    _, cerr, cst = first_add('C', recipient('A'), 'victim')
    sync('C', 'A')
    tampered = File.binread(store('A'))
    _, gerr, gst = get('A', 'FAKE_A1')
    _, aerr, ast = w('A', ['const', 'add', 'FAKE_A1', 'would-leak-0005', '--secret'])
    unchanged = File.binread(store('A')) == tampered && File.binread(keyfile('A')) == saved_key
    _, nerr, nst = w('A', 'secrets adopt')
    out, yerr, yst = w('A', 'secrets adopt --yes')
    after, = get('A', 'FAKE_A1')
    ok = cst.success? && gst.exitstatus == 78 && gerr.include?('not proven by a rotation') &&
         gerr.include?('wayu secrets adopt --yes') && ast.exitstatus == 78 && unchanged &&
         nst.exitstatus == 64 && yst.success? && out.include?(JSON.parse(tampered)['key_id']) && after == 'attacker-0004'
    File.binwrite(store('A'), saved_store)
    File.binwrite("#{@machines['A'][:data]}/entries.json", saved_entries)
    File.binwrite(keyfile('A'), saved_key)
    restored, = get('A', 'FAKE_A1')
    check('attacker key accepted', ok && restored == 'fake-a1-0001',
          "#{cerr} | #{gst.exitstatus} #{gerr} | #{ast.exitstatus} #{aerr} | #{nerr} | #{yerr} | #{after} #{restored}")
  end

  def test_concurrent_rekey_doctor_error
    print 'Test 13: concurrent rekey on two machines: doctor names the value that does not decrypt (78)... '
    sync('A', 'B')
    saved_store = File.binread(store('A'))
    saved_key = File.binread(keyfile('A'))
    get('B', 'FAKE_A1')
    saved_key_b = File.binread(keyfile('B'))
    w('A', 'secrets rekey')
    w('B', 'secrets rekey')
    a = doc('A')
    b = doc('B')
    a['values']['FAKE_A2'] = b['values']['FAKE_A2'] # B's value under B's key lands in A's file
    File.write(store('A'), JSON.pretty_generate(a) + "\n")
    rows = doctor_rows('A')
    _, _, dst = w('A', 'doctor')
    bad = rows.find { |r| r['name'] == 'secrets values' && r['status'] == 'error' }
    File.binwrite(store('A'), saved_store)
    File.binwrite(keyfile('A'), saved_key)
    File.binwrite(keyfile('B'), saved_key_b)
    sync('A', 'B')
    ok = bad && bad['message'].include?('FAKE_A2') && !bad['message'].include?('FAKE_A1') && dst.exitstatus == 78
    check('concurrent rekey not reported', ok, rows.select { |r| r['name'].start_with?('secrets') }.inspect)
  end

  def test_recovery_unlock
    print 'Test 14: recovery: short 65; add; D (no identity) unlocks with stdin passphrase; wrong 65... '
    _, serr, sst = w('A', 'secrets recovery add', stdin: "short\n")
    _, err, st = w('A', 'secrets recovery add', stdin: "#{PASS}\n")
    has = doc('A')['recovery'].is_a?(Hash)
    sync('A', 'D')
    _, werr, wst = w('D', 'secrets recovery unlock', stdin: "wrong passphrase 0000\n")
    _, uerr, ust = w('D', 'secrets recovery unlock', stdin: "#{PASS}\n")
    out, gerr, gst = get('D', 'FAKE_A1')
    _, rerr, rst = w('A', 'secrets recovery rm')
    ok = sst.exitstatus == 65 && st.success? && has && wst.exitstatus == 65 && werr.include?('Wrong recovery passphrase, or the recovery entry was modified') &&
         ust.success? && uerr.include?('wayu secrets recipient add') && gst.success? && out == 'fake-a1-0001' &&
         rst.exitstatus == 64 && !(err + uerr).include?(PASS)
    check('recovery wrong', ok, "#{serr} | #{err} | #{werr} | #{uerr} | #{gerr} | #{rerr}")
  end

  def test_fixture_migration_and_restore_rewrap
    print 'Test 15: 7.0 v1 fixture: reads as is; migrates (backup = fixture); backup restore re-wraps... '
    m = machine('F')
    FileUtils.cp("#{FIXTURE}/secrets.json", store('F'))
    FileUtils.cp("#{FIXTURE}/entries.json", "#{m[:data]}/entries.json")
    FileUtils.cp("#{FIXTURE}/secret.key", keyfile('F'))
    [store('F'), keyfile('F'), "#{m[:data]}/entries.json"].each { |f| File.chmod(0o600, f) }
    fixture = File.binread("#{FIXTURE}/secrets.json")
    out, _, st = get('F', 'FAKE_V1_TOKEN')
    untouched = File.binread(store('F')) == fixture
    _, err, ast = first_add('F', @rb, 'boxb')
    d = doc('F')
    backup_ok = companions('F').any? { |f| File.binread(f) == fixture }
    run_out, = Open3.capture3(env_for('F'), @wayu_bin, 'secrets', 'run', 'FAKE_V1_RUN', '--', 'sh', '-c', 'printf %s "$FAKE_V1_RUN"',
                              unsetenv_others: true)
    # Restore the entries.json backup taken just before the upgrade: its
    # secrets.json copy is version 1, the live store version 2: the result
    # keeps the recipients.
    _, rerr, rst = w('F', 'backup restore entries --yes')
    r = doc('F')
    after, = get('F', 'FAKE_V1_TOKEN')
    ok = st.success? && out == 'fake-v1-token-0001' && untouched && ast.success? && err.include?('is now version 2') &&
         d['version'] == 2 && d['run_only'] == ['FAKE_V1_RUN'] && backup_ok && run_out == 'fake-v1-runonly-0002' &&
         rst.success? && r['version'] == 2 && r['recipients'].size == 2 && after == 'fake-v1-token-0001'
    check('fixture migration wrong', ok, "#{st.exitstatus} #{out} #{err} | #{rerr} #{r.inspect[0, 200]}")
  end

  def test_doctor_v2_rows
    print 'Test 16: doctor on v2: recipients info, identity ok, values ok; exit 0... '
    rows = doctor_rows('A')
    find = ->(n, s) { rows.find { |r| r['name'] == n && r['status'] == s } }
    ok = find.call('secrets recipients', 'info') && find.call('secrets identity', 'ok') &&
         find.call('secrets values', 'ok') &&
         rows.none? { |r| r['name'].start_with?('secrets') && r['status'] == 'error' }
    check('doctor rows wrong', ok, rows.select { |r| r['name'].start_with?('secrets') }.inspect)
  end

  def test_doctor_git_and_conflict_warnings
    print 'Test 17: doctor warns: key files in a git work tree, sync-conflict copies... '
    if `command -v git 2>/dev/null`.strip.empty?
      puts 'skipped (git not installed)'
      return
    end
    cfg = @machines['A'][:config]
    Open3.capture3('git', 'init', '-q', cfg)
    rows = doctor_rows('A')
    warns = rows.select { |r| r['name'] == 'secrets key files' && r['status'] == 'warning' }
    File.write("#{cfg}/.gitignore", "secret.key\nidentity.key\n")
    rows2 = doctor_rows('A')
    FileUtils.rm_rf(["#{cfg}/.git", "#{cfg}/.gitignore"])
    conflict = "#{@machines['A'][:data]}/secrets.sync-conflict-20260101-000000-ABC.json"
    File.write(conflict, '{}')
    rows3 = doctor_rows('A')
    File.delete(conflict)
    ok = warns.any? { |r| r['message'].include?('identity.key') } && warns.any? { |r| r['message'].include?('secret.key') } &&
         rows2.none? { |r| r['name'] == 'secrets key files' } &&
         rows3.any? { |r| r['name'] == 'secrets sync' && r['status'] == 'warning' && r['message'].include?('sync-conflict') }
    check('doctor warnings wrong', ok, "#{warns.inspect} #{rows3.select { |r| r['name'] == 'secrets sync' }.inspect}")
  end

  # A fake `security` (as in test_secrets_store.rb): items are files
  # <dir>/<account>; `-i` reads the command on stdin.
  def fake_security(dir)
    FileUtils.mkdir_p("#{dir}/bin")
    File.write("#{dir}/bin/security", <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{dir}/argv.log"
      if [ "$1" = -i ]; then IFS= read -r line; eval "set -- $line"; fi
      cmd=$1; shift; acct=; pw=; upd=
      while [ $# -gt 0 ]; do
        case $1 in -a) acct=$2; shift ;; -w) [ $# -gt 1 ] && { pw=$2; shift; } ;; -U) upd=1 ;; -s|-l) shift ;; esac
        shift
      done
      case $cmd in
        find-generic-password) [ -f "#{dir}/$acct" ] || exit 44; cat "#{dir}/$acct" ;;
        add-generic-password) [ -z "$upd" ] && [ -f "#{dir}/$acct" ] && exit 45; printf '%s' "$pw" > "#{dir}/$acct" ;;
        *) exit 1 ;;
      esac
    SH
    File.chmod(0o755, "#{dir}/bin/security")
  end

  def keystore_test_bin
    return nil if `command -v odin 2>/dev/null`.strip.empty?
    out = "#{@tmp_home}/wayu-keystore-test"
    root = File.expand_path('../..', __dir__)
    _, err, st = Open3.capture3('odin', 'build', 'src', '-define:WAYU_TEST_KEYSTORE=true', "-out:#{out}", chdir: root)
    raise "keystore test build failed: #{err}" unless st.success?
    out
  end

  def test_keychain_identity_off_argv
    print 'Test 18: keychain backend (fake security): identity item created once, never on argv... '
    bin = keystore_test_bin
    if bin.nil?
      puts 'skipped (odin not installed)'
      return
    end
    m = machine('K')
    kc = "#{@tmp_home}/fake-keychain"
    fake_security(kc)
    path = "#{m[:config]}/wayu.toml"
    File.write(path, File.read(path).sub('backend = "file"', 'backend = "keychain"'))
    kenv = { 'WAYU_TEST_SECURITY_BIN' => "#{kc}/bin/security" }
    r1, e1, s1 = w('K', 'secrets identity', bin: bin, extra: kenv)
    r2, _, s2 = w('K', 'secrets identity', bin: bin, extra: kenv)
    items = Dir.children(kc).reject { |n| %w[bin argv.log].include?(n) }
    item = items.find { |n| n.end_with?('-identity') }
    secret = item ? File.read("#{kc}/#{item}") : ''
    log = File.read("#{kc}/argv.log")
    # A full round trip through the keychain: K adds a fresh machine G.
    machine('G')
    w('K', ['const', 'add', 'FAKE_K', 'fake-k-0006', '--secret'], bin: bin, extra: kenv)
    _, aerr, ast = first_add('K', recipient('G'), 'boxg', bin: bin, extra: kenv)
    sync('K', 'G')
    w('G', 'secrets adopt --yes')
    out, = get('G', 'FAKE_K')
    ok = s1.success? && s2.success? && r1 == r2 && r1.start_with?('age1') && item && item.match?(/\Awayu-\h{16}-identity\z/) &&
         secret.start_with?('AGE-SECRET-KEY-1') && !log.include?(secret) && !log.include?('AGE-SECRET-KEY') &&
         ast.success? && out == 'fake-k-0006'
    check('keychain identity wrong', ok, "#{e1} | #{items.inspect} | #{aerr} | #{out}")
  end
  # ---------------------------------------------------------------------
  # Review findings (each attack fails before the fix)

  # Fresh machines a (writer) and b (reader) sharing a version 2 store
  # with FAKE_T, b adopted.
  def pair(a, b)
    [a, b].each { |m| machine(m) }
    w(a, ['const', 'add', 'FAKE_T', 'fake-t-0007', '--secret'])
    _, err, st = first_add(a, recipient(b), "box#{b.downcase}")
    raise "pair #{a} #{b}: #{err}" unless st.success?
    sync(a, b)
    _, err, st = w(b, 'secrets adopt --yes')
    raise "adopt #{b}: #{err}" unless st.success?
  end

  def write_doc(name, d)
    File.write(store(name), JSON.pretty_generate(d) + "\n")
  end

  def test_downgrade_to_v1_refused
    print 'Test 19: v2 -> v1 downgrade: 78 everywhere (get, add, rekey, doctor), store untouched; sync or adopt --yes fix it... '
    pair('P1', 'P2')
    d = doc('P1')
    write_doc('P1', { 'version' => 1, 'cipher' => d['cipher'], 'values' => d['values'] })
    down = File.binread(store('P1'))
    _, gerr, gst = get('P1', 'FAKE_T')
    _, aerr, ast = w('P1', ['const', 'add', 'FAKE_NEW', 'fake-new-0008', '--secret'])
    _, _, rst = w('P1', 'secrets rekey')
    rows = doctor_rows('P1')
    untouched = File.binread(store('P1')) == down
    # The fix it names: sync the version 2 file again.
    sync('P2', 'P1')
    out, _, sst = get('P1', 'FAKE_T')
    # The other fix: back to one machine on purpose.
    write_doc('P2', { 'version' => 1, 'cipher' => d['cipher'], 'values' => d['values'] })
    _, yerr, yst = w('P2', 'secrets adopt --yes')
    one, _, ost = get('P2', 'FAKE_T')
    ok = gst.exitstatus == 78 && gerr.include?('downgrade') && gerr.include?('wayu secrets adopt --yes') &&
         ast.exitstatus == 78 && rst.exitstatus == 78 && untouched &&
         rows.any? { |r| r['status'] == 'error' && r['message'].include?('downgrade') } &&
         sst.success? && out == 'fake-t-0007' && yst.success? && yerr.empty? && ost.success? && one == 'fake-t-0007'
    check('downgrade accepted', ok, "#{gst.exitstatus} #{gerr} | #{ast.exitstatus} #{aerr} | #{rst.exitstatus} | #{yerr}")
  end

  def test_rm_drops_tampered_entry_first
    print 'Test 20: injected recipient / tampered recovery: the error names rm, and that rm works... '
    pair('Q1', 'Q2')
    machine('Q3')
    machine('Q4')
    d = doc('Q1')
    d['recipients'] << { 'name' => 'intruder', 'recipient' => recipient('Q4'), 'stanza' => d['recipients'][0]['stanza'] }
    write_doc('Q1', d)
    _, aerr, ast = w('Q1', "secrets recipient add #{recipient('Q3')} --name q3")
    _, rerr, rst = w('Q1', 'secrets recipient rm intruder --yes')
    _, a2err, a2st = w('Q1', "secrets recipient add #{recipient('Q3')} --name q3")
    w('Q1', 'secrets recovery add', stdin: "#{PASS}\n")
    d = doc('Q1')
    d['recovery']['stanza'] = d['recipients'][0]['stanza'] if d['recovery']
    write_doc('Q1', d)
    _, berr, bst = w('Q1', 'secrets rekey')
    _, cerr, cst = w('Q1', 'secrets recovery rm --yes')
    sync('Q1', 'Q2')
    out, = get('Q2', 'FAKE_T')
    ok = ast.exitstatus == 78 && aerr.include?('wayu secrets recipient rm intruder --yes') &&
         rst.success? && a2st.success? &&
         bst.exitstatus == 78 && berr.include?('wayu secrets recovery rm --yes') && cst.success? &&
         !doc('Q1').key?('recovery') && out == 'fake-t-0007'
    check('guidance does not work', ok, "#{aerr} | #{rst.exitstatus} #{rerr} | #{a2err} | #{berr} | #{cst.exitstatus} #{cerr}")
  end

  def test_broken_own_stanza_guidance
    print 'Test 21: a machine whose stanza was tampered with: the rm + add it names (on another machine) works... '
    pair('R1', 'R2')
    machine('R3')
    w('R1', "secrets recipient add #{recipient('R3')} --name r3")
    # The synced file itself carries the broken stanza.
    d = doc('R1')
    mine = d['recipients'].find { |r| r['name'] == 'r3' }
    mine['stanza'] = d['recipients'].find { |r| r['name'] == 'boxr2' }['stanza']
    write_doc('R1', d)
    sync('R1', 'R3')
    _, err, st = w('R3', 'secrets adopt --yes')
    fix = err.strip[/run: (wayu secrets recipient rm .*)\z/, 1].to_s
    steps = fix.split(' && ').map { |c| c.split(' ').drop(1) }
    results = steps.map { |argv| w('R1', argv) }
    sync('R1', 'R3')
    _, _, ast = w('R3', 'secrets adopt --yes')
    out, = get('R3', 'FAKE_T')
    ok = st.exitstatus == 78 && !err.include?('backup restore') && steps.size == 2 &&
         results.all? { |r| r[2].success? } && ast.success? && out == 'fake-t-0007'
    check('own-stanza guidance wrong', ok, "#{err} | #{results.map { |r| r[1] }.join(' | ')}")
  end

  def test_removed_recipient_back_not_adopted
    print 'Test 22: a verified rotation that lists a machine this one saw removed: 78, diff printed; adopt --yes takes it... '
    pair('S1', 'S2')
    machine('S3')
    s3 = recipient('S3')
    w('S1', "secrets recipient add #{s3} --name s3")
    sync('S1', 'S2')
    get('S2', 'FAKE_T')
    w('S1', 'secrets recipient rm s3 --yes')
    sync('S1', 'S2')
    _, derr, dst = get('S2', 'FAKE_T') # adopts the rotation, sees s3 removed
    w('S1', "secrets recipient add #{s3} --name s3")
    w('S1', 'secrets rekey')
    sync('S1', 'S2')
    _, berr, bst = get('S2', 'FAKE_T')
    aout, _, ast = w('S2', 'secrets adopt --yes')
    out, = get('S2', 'FAKE_T')
    ok = dst.success? && derr.include?('rotation from') && derr.include?('recipients: -s3') &&
         bst.exitstatus == 78 && berr.include?('saw removed') && berr.include?('s3') && berr.include?('wayu secrets adopt --yes') &&
         ast.success? && aout.include?('+s3') && out == 'fake-t-0007'
    check('re-added machine adopted silently', ok, "#{derr} | #{bst.exitstatus} #{berr} | #{aout}")
  end

  def test_rollback_refused_not_adoptable
    print 'Test 23: rollback to a key this machine replaced: own error (no adopt), adopt and recovery unlock refuse it... '
    pair('U1', 'U2')
    machine('U3')
    w('U1', "secrets recipient add #{recipient('U3')} --name u3")
    w('U1', 'secrets recovery add', stdin: "#{PASS}\n")
    sync('U1', 'U2')
    old = File.binread(store('U1'))
    w('U1', 'secrets recipient rm u3 --yes')
    sync('U1', 'U2')
    get('U2', 'FAKE_T')
    File.binwrite(store('U2'), old)
    _, gerr, gst = get('U2', 'FAKE_T')
    _, aerr, ast = w('U2', 'secrets adopt --yes')
    _, uerr, ust = w('U2', 'secrets recovery unlock', stdin: "#{PASS}\n")
    _, cerr, cst = w('U2', 'secrets cache')
    sync('U1', 'U2')
    out, = get('U2', 'FAKE_T')
    ok = gst.exitstatus == 78 && gerr.include?("older than this machine's data key") && !gerr.include?('adopt') &&
         ast.exitstatus == 78 && aerr.include?('older than') && ust.exitstatus == 78 && uerr.include?('older than') &&
         cst.exitstatus == 78 && cerr.lines.size == 1 && out == 'fake-t-0007'
    check('rollback adoptable', ok, "#{gerr} | #{ast.exitstatus} #{aerr} | #{ust.exitstatus} #{uerr} | #{cerr}")
  end

  def test_recovery_rm_note_and_params
    print 'Test 24: recovery key refused as a machine (65); rm says to replace the passphrase; a 1 GiB argon2id entry is refused at once (78)... '
    pair('V1', 'V2')
    machine('V3')
    w('V1', "secrets recipient add #{recipient('V3')} --name v3")
    w('V1', 'secrets recovery add', stdin: "#{PASS}\n")
    before = File.binread(store('V1'))
    _, kerr, kst = w('V1', "secrets recipient add #{doc('V1')['recovery']['recipient']} --name rec")
    rec_refused = kst.exitstatus == 65 && kerr.include?("recovery passphrase's own key") && File.binread(store('V1')) == before
    rout, _, rst = w('V1', 'secrets recipient rm v3 --yes')
    machine('V4')
    d = doc('V1')
    d['recovery'].merge!('m' => 1_048_576, 't' => 16, 'p' => 16)
    write_doc('V4', d)
    FileUtils.cp("#{@machines['V1'][:data]}/entries.json", "#{@machines['V4'][:data]}/entries.json")
    t0 = Time.now
    _, uerr, ust = w('V4', 'secrets recovery unlock', stdin: "#{PASS}\n")
    secs = Time.now - t0
    rows = doctor_rows('V1')
    ok = rec_refused && rst.success? && rout.include?('wayu secrets recovery rm --yes && wayu secrets recovery add') &&
         rout.include?('have not synced') &&
         ust.exitstatus == 78 && uerr.include?('recovery entry was modified') && uerr.include?('recovery rm --yes') &&
         secs < 3 && rows.none? { |r| r['name'].start_with?('secrets') && r['status'] == 'error' }
    check('recovery note / params wrong', ok, "#{rout} | #{ust.exitstatus} #{uerr} #{secs}")
  end

  def test_wording
    print 'Test 25: wording: "version": 2.0 is an invalid version; v2 decrypt errors name the data key, not the master key... '
    pair('W1', 'W2')
    w('W1', ['const', 'add', 'FAKE_U', 'fake-u-0009', '--secret'])
    good = File.read(store('W1'))
    File.write(store('W1'), good.sub('"version": 2,', '"version": 2.0,'))
    _, verr, vst = get('W1', 'FAKE_T')
    d = JSON.parse(good)
    d['values']['FAKE_T'], d['values']['FAKE_U'] = d['values']['FAKE_U'], d['values']['FAKE_T']
    write_doc('W1', d)
    _, derr, dst = get('W1', 'FAKE_T')
    File.write(store('W1'), good)
    ok = vst.exitstatus == 78 && verr.include?('unsupported version') && !verr.include?('unknown field') &&
         dst.exitstatus == 78 && derr.include?("data key #{d['key_id']}") && !derr.include?('master key') &&
         derr.include?('wayu const add FAKE_T --secret')
    check('wording wrong', ok, "#{verr} | #{derr}")
  end
end

SecretsMultiIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
