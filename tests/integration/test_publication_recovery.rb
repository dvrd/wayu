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
  %w[entries.json core.bash core.zsh].product(%w[before after]).each do |target, phase|
    WayuFixture.with_directory('case', workspace) do |dir|
      model = EntryModel.new(dir, ENV.fetch('WAYU_BIN', 'bin/wayu'))
      begin
        model.setup
        model.sequence(seed)
        PublicationPhases.interrupt(instrumented, model, target, phase, 'interrupted')
        if target != 'entries.json' || phase == 'after'
          model.expected['aliases']['interrupted'] = 'echo interrupted'
        end
        model.verify
        2.times { model.command('build') }
        model.verify_shells
        model.apply('aliases', 'add', 'after_recovery', 'true')
        puts JSON.generate(model.diagnostics(seed).merge(target: target, phase: phase,
          interrupted_alias: 'interrupted', instrumented_sha256: build_hash, result: 'recovered'))
      rescue StandardError => error
        warn JSON.generate(model.diagnostics(seed).merge(target: target, phase: phase,
          interrupted_alias: 'interrupted', instrumented_sha256: build_hash, first_difference: error.message))
        raise
      end
    end
  end
end
