require 'json'
require 'open3'
require_relative 'fixture'
require 'digest'

class EntryModel
  attr_reader :env, :data, :expected, :trace

  def initialize(home, binary)
    @binary = File.expand_path(binary)
    @expected = { 'aliases' => {}, 'env' => {} }
    @data = File.join(home, 'data')
    @env = { 'HOME' => home, 'WAYU_CONFIG_DIR' => File.join(home, 'config'), 'WAYU_DATA_DIR' => @data,
             'SHELL' => '/bin/bash', 'PATH' => ENV.fetch('PATH'), 'NO_COLOR' => '1', 'LC_ALL' => 'C' }
    %w[ASAN_OPTIONS LSAN_OPTIONS UBSAN_OPTIONS].each { |key| @env[key] = ENV[key] if ENV[key] }
    @trace = []
    @names = { 'aliases' => [], 'env' => [] }
  end

  # Every name an operation touched is checked in the host shells, so a name
  # that was removed, only previewed or never committed must be absent.
  def mention(kind, name)
    @names[kind] << name unless @names[kind].include?(name)
  end

  def command(*args)
    out, err, status = Open3.capture3(@env, @binary, *args, unsetenv_others: true)
    raise "#{args.inspect}: #{status.inspect} #{err}" unless status.success?
    out
  end

  def setup
    %w[bash zsh].each { |shell| command('init', '--shell', shell) }
  end

  def apply(kind, action, name, value = nil, dry: false)
    args = [kind == 'env' ? 'const' : 'alias', action, name, value].compact
    args.unshift('--dry-run') if dry
    @trace << args
    mention(kind, name)
    command(*args)
    unless dry
      action == 'add' ? @expected[kind][name] = value : @expected[kind].delete(name)
    end
    verify
  end

  def verify
    stored = JSON.parse(File.read(File.join(@data, 'entries.json')))
    model = { 'version' => 1, 'paths' => [] }
    @expected.each do |kind, values|
      model[kind] = values.map { |name, value| { 'name' => name, 'value' => value } }
    end
    raise "expected #{model.inspect}, got #{stored.inspect}" unless stored == model
  end

  def sequence(seed)
    random = Random.new(seed)
    apply('aliases', 'add', 'probe_anchor', 'echo anchor')
    12.times do |i|
      kind = random.rand(2).zero? ? 'env' : 'aliases'
      name = (kind == 'env' ? 'ENV_PROBE_' : 'probe_') + random.rand(4).to_s
      if @expected[kind].key?(name) && random.rand(2).zero?
        apply(kind, 'remove', name, dry: i % 4 == 3)
      else
        apply(kind, 'add', name, "value_#{i}", dry: i % 4 == 3)
      end
    end
  end

  # One name as a fresh host shell sees it: [status, stdout, stderr]. Status 1
  # means the shell loaded its runtime and does not have the name.
  def probe(shell, kind, name)
    args = shell == 'bash' ? ['--noprofile', '--norc'] : ['-f']
    lookup = kind == 'env' ? %q{printenv "$2"} : %q{alias "$2"}
    out, err, status = Open3.capture3(@env, shell, *args, '-c',
      %Q{source "$1" || exit 97; #{lookup}}, shell, "#{@data}/init.#{shell}", name, unsetenv_others: true)
    raise "#{shell} could not load its runtime: #{err}" if status.exitstatus == 97
    [status, out, err]
  end

  def verify_shells
    %w[bash zsh].each do |shell|
      @names.each do |kind, names|
        names.each do |name|
          status, out, err = probe(shell, kind, name)
          value = @expected[kind][name]
          ok = if value.nil?
                 status.exitstatus == 1
               elsif kind == 'env'
                 status.success? && out == "#{value}\n"
               else
                 status.success? && ["alias #{name}='#{value}'", "#{name}='#{value}'", "#{name}=#{value}"].include?(out.strip)
               end
          raise "#{shell} #{name}: expected #{value.inspect}, got #{status.exitstatus} #{out.inspect} #{err}" unless ok
        end
      end
    end
  end

  def diagnostics(seed)
    { seed: seed, trace: @trace, platform: RUBY_PLATFORM, binary_sha256: Digest::SHA256.file(@binary).hexdigest,
      revision: `git rev-parse HEAD`.strip, shells: %w[bash zsh].map { |s| `#{s} --version`.lines.first.strip } }
  end
end
