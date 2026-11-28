#!/usr/bin/env ruby
require_relative '../scenarios/publication_phases'
require 'optparse'

seed = 17
OptionParser.new do |p|
  p.on('--all-phases') {}
  p.on('--seed N', Integer) { |n| seed = n }
end.parse!
WayuFixture.with_directory('wayu-replay') do |workspace|
  instrumented = PublicationPhases.build(workspace)
  build_hash = Digest::SHA256.file(instrumented).hexdigest
  compiler = `odin version`.strip
  # The phase controls exist only in the instrumented build.
  candidate = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
  raise 'the instrumented build has no phase controls' unless File.binread(instrumented).include?('WAYU_TEST_PHASE')
  raise 'the candidate binary contains test phase controls' if File.binread(candidate).include?('WAYU_TEST_PHASE')
  files = %w[entries.json core.bash core.zsh]
  files.product(%w[before after]).each do |target, phase|
    WayuFixture.with_directory('case', workspace) do |dir|
      model = EntryModel.new(dir, ENV.fetch('WAYU_BIN', 'bin/wayu'))
      begin
        model.setup
        model.sequence(seed)
        before = files.map { |file| File.binread(File.join(model.data, file)) }
        PublicationPhases.interrupt(instrumented, model, target, phase, 'interrupted')
        model.mention('aliases', 'interrupted')
        if target != 'entries.json' || phase == 'after'
          model.expected['aliases']['interrupted'] = 'echo interrupted'
        end
        model.verify
        # The store is renamed first, then each shell's core, the active shell
        # (bash) first. A file renamed before the kill holds the new entry;
        # every later file is byte for byte what it was.
        observed = files.map { |file| File.binread(File.join(model.data, file)) }
        renamed = files.index(target) + (phase == 'after' ? 1 : 0)
        files.each_with_index do |file, index|
          if index < renamed
            raise "#{file} lacks the new entry after its rename" unless observed[index].include?('interrupted')
          else
            raise "#{file} changed before its rename" unless observed[index] == before[index]
          end
        end
        # A renamed runtime is complete: a fresh shell loads it and has the
        # entry. A shell whose runtime was not reached still has the old one.
        { 'core.bash' => 'bash', 'core.zsh' => 'zsh' }.each do |file, shell|
          status, out, = model.probe(shell, 'aliases', 'interrupted')
          if files.index(file) < renamed
            raise "fresh #{shell} did not load the renamed #{file}: #{out}" unless status.success? && out.include?('echo interrupted')
          else
            raise "fresh #{shell} has an entry before #{file} was renamed: #{out}" unless status.exitstatus == 1
          end
        end
        2.times { model.command('build') }
        model.verify_shells
        model.apply('aliases', 'add', 'after_recovery', 'true')
        puts JSON.generate(model.diagnostics(seed).merge(target: target, phase: phase,
          interrupted_alias: 'interrupted', instrumented_sha256: build_hash, compiler: compiler, result: 'recovered'))
      rescue StandardError => error
        warn JSON.generate(model.diagnostics(seed).merge(target: target, phase: phase,
          interrupted_alias: 'interrupted', instrumented_sha256: build_hash, compiler: compiler, first_difference: error.message))
        raise
      end
    end
  end
end
