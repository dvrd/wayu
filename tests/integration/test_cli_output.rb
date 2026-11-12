#!/usr/bin/env ruby
# CLI output contract: errors on stderr (one per failure), --help without a
# config, no ANSI escapes under NO_COLOR / --no-color / a pipe, and valid
# --json everywhere it is accepted (OKAMI-237, 238, 239, 282).

require 'open3'
require 'json'
require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'

class CliOutputIntegrationTest
  include WayuTestHelper

  ESC = "\e".freeze

  # Commands run against an initialized config with a few entries.
  COMMANDS = [
    '--help', 'help', 'version',
    'path list', 'path list --full', 'path list --json', 'path --help', 'path get /nope',
    'alias list', 'alias --help', 'const list', 'const list --full', 'const --help',
    'backup list', 'backup --help', 'backup restore path',
    'doctor', 'doctor --json', 'plugin list', 'plugin list --json', 'plugin search', 'plugin --help',
    'completions list', 'completions --help', 'toml validate', 'toml show', 'toml keys',
    'template list', 'hooks', 'function list', 'export list', 'build help',
    'init --help', 'search ll', 'search ll --json',
    'nosuchcmd', 'path add', 'path list --bogus', 'path add /tmp --json'
  ].freeze

  HELP_COMMANDS = %w[path alias const constants env backup plugin init config build export
                     toml doctor template hooks function reload search completions].freeze

  def initialize
    setup_test_env
  end

  def run
    puts '🧾 Testing CLI output contract...'
    puts
    begin
      build_project
      test_help_without_config
      test_one_error_before_init
      initialize_wayu
      seed_entries
      test_errors_on_stderr
      test_no_escape_codes_when_piped
      test_no_escape_codes_with_no_color
      test_force_color_keeps_colors
      test_json_documents
      test_json_schema
      test_json_empty_lists
      test_json_external_paths
      test_json_rejected_where_unsupported
      test_help_lists_every_command
      test_help_lists_every_exit_code
      test_control_chars_shown_escaped
    ensure
      teardown_test_env
    end
    print_summary('CLI output')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # [stdout, stderr, status] with stdout/stderr kept apart.
  def run_split(args, env: {}, home: @tmp_home)
    full_env = ENV.to_h.merge('HOME' => home).merge(env)
    %w[NO_COLOR FORCE_COLOR CLICOLOR_FORCE WAYU_PLAIN].each { |k| full_env.delete(k) unless env.key?(k) }
    out, err, status = Open3.capture3(full_env, "#{@wayu_bin} #{args}")
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  end

  def check(name, ok, detail = '')
    print "#{name}... "
    if ok
      puts '✓'
      @passed += 1
    else
      puts '✗'
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def seed_entries
    run_split('path add /usr/bin')
    run_split('alias add ll "ls -la"')
    run_split('const add EDITOR nvim')
  end

  def test_help_without_config
    fresh = Dir.mktmpdir("wayu_cli_fresh_")
    bad = []
    HELP_COMMANDS.each do |cmd|
      ['--help', 'help', '-h'].each do |h|
        out, err, st = run_split("#{cmd} #{h}", home: fresh)
        bad << "#{cmd} #{h} (exit #{st.exitstatus}, stderr #{err.lines.first&.strip})" if !st.success? || !err.empty? || out.empty?
      end
    end
    check('--help works for every command without a config', bad.empty?, bad.first(5).join('; '))
  ensure
    FileUtils.rm_rf(fresh)
  end

  def test_one_error_before_init
    fresh = Dir.mktmpdir("wayu_cli_fresh2_")
    bad = []
    ['path list', 'path list --json', 'alias list', 'const list', 'search x'].each do |cmd|
      out, err, st = run_split(cmd, home: fresh)
      errors = err.scan('ERROR:').size
      bad << "#{cmd}: exit #{st.exitstatus}, #{errors} errors, stdout #{out.size}B" unless st.exitstatus == 78 && errors == 1 && out.empty?
    end
    check('Before init: one error on stderr, exit 78, empty stdout', bad.empty?, bad.join('; '))
  ensure
    FileUtils.rm_rf(fresh)
  end

  def test_errors_on_stderr
    bad = []
    ['backup restore path', 'path get /nope', 'path add', 'nosuchcmd', 'path list --bogus'].each do |cmd|
      out, err, st = run_split(cmd)
      bad << "#{cmd}: stdout has ERROR" if out.include?('ERROR')
      bad << "#{cmd}: stderr empty" if err.strip.empty?
      bad << "#{cmd}: exit 0" if st.success?
    end
    check('Errors go to stderr, never stdout', bad.empty?, bad.join('; '))
  end

  def escape_hits(env = {}, suffix = '')
    COMMANDS.map do |cmd|
      out, err, = run_split("#{cmd}#{suffix}", env: env)
      "#{cmd}#{suffix}" if out.include?(ESC) || err.include?(ESC)
    end.compact
  end

  def test_no_escape_codes_when_piped
    hits = escape_hits
    check('No escape codes when output is a pipe', hits.empty?, hits.first(5).join(', '))
  end

  def test_no_escape_codes_with_no_color
    hits = escape_hits('NO_COLOR' => '1', 'FORCE_COLOR' => '1')
    check('NO_COLOR=1 beats FORCE_COLOR: no escape codes', hits.empty?, hits.first(5).join(', '))
    hits = escape_hits({ 'FORCE_COLOR' => '1' }, ' --no-color')
    check('--no-color beats FORCE_COLOR: no escape codes', hits.empty?, hits.first(5).join(', '))
  end

  def test_force_color_keeps_colors
    out, _err, = run_split('path list', env: { 'FORCE_COLOR' => '1' })
    _o, err, = run_split('path get /nope', env: { 'FORCE_COLOR' => '1' })
    check('FORCE_COLOR=1 keeps colors in a pipe (stdout and stderr)', out.include?(ESC) && err.include?(ESC))
  end

  def valid_json?(text)
    JSON.parse(text)
    true
  rescue JSON::ParserError
    false
  end

  def test_json_documents
    bad = []
    ['path list --json', 'path list --json --full', 'alias list --json', 'const list --json',
     'backup list --json', 'plugin list --json', 'search ll --json', 'search zzzz --json', 'doctor --json'].each do |cmd|
      out, err, st = run_split(cmd)
      bad << "#{cmd} (exit #{st.exitstatus}) #{err.lines.first&.strip}" unless valid_json?(out)
    end
    check('Every --json output is one valid JSON document', bad.empty?, bad.join('; '))
  end

  # OKAMI-185: every list --json follows the schema documented in docs/cli.md
  # ("JSON output"): top-level keys and the exact key set of each row.
  JSON_SCHEMA = {
    'path list --json' => [%w[paths], %w[path source exists]],
    'alias list --json' => [%w[aliases], %w[alias command source]],
    'const list --json' => [%w[constants], %w[constant value source]],
    'plugin list --json' => [%w[plugins count enabled], %w[name enabled priority shell url commit installed_path conflicts]],
    'backup list --json' => [%w[backups], %w[file count entries]],
    'search ll --json' => [%w[results query count], %w[type name value match field score]],
    'doctor --json' => [%w[checks summary], %w[name status message fixable]],
    # Version 1 store here (no rows); test_secrets_multi.rb checks the rows.
    'secrets recipient list --json' => [%w[recipients key_id recovery], %w[name recipient this_machine]],
  }.freeze

  def test_json_schema
    bad = []
    JSON_SCHEMA.each do |cmd, (top, row)|
      out, = run_split(cmd)
      doc = valid_json?(out) ? JSON.parse(out) : {}
      bad << "#{cmd}: top keys #{doc.keys}" unless doc.keys.sort == top.sort
      rows = doc[top.first] || []
      bad << "#{cmd}: no rows" if rows.empty? && cmd !~ /plugin|secrets/
      rows.each { |r| bad << "#{cmd}: row keys #{r.keys}" unless r.keys.sort == row.sort }
    end
    backup = JSON.parse(run_split('backup list --json').first)['backups'].first
    entry_keys = %w[index timestamp size_bytes path pre_restore]
    bad << "backup entry keys #{backup['entries'].first.keys}" unless backup && backup['entries'].all? { |e| e.keys.sort == entry_keys.sort }
    summary = JSON.parse(run_split('doctor --json').first)['summary']
    bad << "doctor summary #{summary.keys}" unless summary.keys.sort == %w[ok warnings errors info fixable].sort
    check('--json output matches the documented schema', bad.empty?, bad.join('; '))
  end

  # Security audit: a stored value holding terminal escapes (OSC title / OSC 52,
  # clear screen, 8-bit CSI) must not reach the terminal raw from the human
  # views; they show it escaped (\x1B, \u009B). --json still carries the
  # exact value. Runs last: it replaces the seeded entries.
  EVIL = "echo \e]0;pwned\a\e[2J\u009b31m".freeze
  EVIL_DIR = "/nonexistent/pwn\e[2Jdir".freeze

  def test_control_chars_shown_escaped
    write_entries(paths: { 'PWN' => EVIL_DIR }, aliases: { 'pwnalias' => EVIL }, env: { 'PWN_TITLE' => EVIL })
    raw = ["\e", "\a", "\u009b"]
    bad = []
    ['alias list', 'alias list --full', 'const list', 'const list --full', 'path list',
     'path list --full', 'search pwn', 'doctor'].each do |cmd|
      out, err, = run_split(cmd)
      hit = raw.find { |c| out.include?(c) || err.include?(c) }
      bad << "#{cmd}: raw #{hit.inspect}" if hit
    end
    %w[alias const].each do |kind|
      out, = run_split("#{kind} list")
      bad << "#{kind} list: escaped value missing" unless out.include?('\x1B]0;pwned\x07\x1B[2J\u009B31m')
    end
    path_out, = run_split('path list')
    bad << 'path list: escaped dir missing' unless path_out.include?('pwn\x1B[2Jdir')

    aliases = JSON.parse(run_split('alias list --json').first)['aliases']
    bad << 'alias --json value changed' unless aliases.any? { |a| a['alias'] == 'pwnalias' && a['command'] == EVIL }
    consts = JSON.parse(run_split('const list --json').first)['constants']
    bad << 'const --json value changed' unless consts.any? { |c| c['constant'] == 'PWN_TITLE' && c['value'] == EVIL }
    paths = JSON.parse(run_split('path list --json').first)['paths']
    bad << 'path --json dir changed' unless paths.any? { |p| p['path'] == EVIL_DIR }
    got, = run_split('const get PWN_TITLE')
    bad << 'const get no longer raw' unless got == "#{EVIL}\n"
    check('Control characters in values are shown escaped; --json and get stay exact', bad.empty?, bad.join('; '))
  end

  def test_json_empty_lists
    home = Dir.mktmpdir("wayu_cli_empty_")
    run_split('init --yes', home: home)
    bad = []
    { 'alias list --json' => 'aliases', 'const list --json' => nil, 'plugin list --json' => 'plugins' }.each do |cmd, key|
      out, _err, = run_split(cmd, home: home, env: { 'PATH' => ENV['PATH'] })
      ok = valid_json?(out) && (key.nil? || JSON.parse(out)[key] == [])
      bad << "#{cmd}: #{out.lines.first&.strip}" unless ok
    end
    check('Empty lists are still JSON', bad.empty?, bad.join('; '))
  ensure
    FileUtils.rm_rf(home)
  end

  def test_json_external_paths
    out, = run_split('path list --json --source external', env: { 'PATH' => "/opt/wayu-ext-test:#{ENV['PATH']}" })
    paths = valid_json?(out) ? JSON.parse(out)['paths'] : []
    check('path list --json --source external lists external entries',
          paths.any? { |p| p['path'] == '/opt/wayu-ext-test' && p['source'] == 'external' },
          out.lines.first(3).join.strip)
  end

  def test_json_rejected_where_unsupported
    bad = []
    ['path add /tmp --json', 'const get EDITOR --json', 'hooks --json', 'toml show --json'].each do |cmd|
      out, err, st = run_split(cmd)
      bad << "#{cmd}: exit #{st.exitstatus}" unless st.exitstatus == 64 && out.empty? && err.include?('--json')
    end
    _o, _e, st = run_split('path --help --json')
    bad << 'path --help --json rejected' unless st.success?
    check('--json is a usage error (64) where there is no JSON output', bad.empty?, bad.join('; '))
  end

  # OKAMI-282: help's COMMANDS section is generated from the command table,
  # so it names every command the completions offer.
  def test_help_lists_every_command
    out, = run_split('help')
    zsh, = run_split('completions zsh')
    commands = zsh[/^_wayu_commands\(\) \{.*?^\}/m].to_s
    names = commands.scan(/^\s+'([a-z-]+):/).flatten.uniq
    missing = names.reject { |n| out.match?(/^\s+(\S+, )*#{Regexp.escape(n)}(,|\s)/) }
    check('help lists every command completions offer', !names.empty? && missing.empty?, "missing: #{missing.join(', ')}")
  end

  # OKAMI-354: `wayu help` EXIT CODES lists every code docs/cli.md documents.
  def test_help_lists_every_exit_code
    doc = File.read(File.expand_path('../../docs/cli.md', __dir__))
    table = doc[/^## Exit codes\n(.*?)(?=^#)/m, 1].to_s
    codes = table.scan(/^\| (\d+) \| `EXIT_/).flatten
    out, = run_split('help --no-color')
    listed = out[/EXIT CODES:(.*)/m, 1].to_s.scan(/^\s+(\d+)\s/).flatten
    missing = codes - listed
    check('help EXIT CODES lists every documented code', codes.size >= 10 && missing.empty?,
          "missing: #{missing.join(', ')}")
  end
end

CliOutputIntegrationTest.new.run
