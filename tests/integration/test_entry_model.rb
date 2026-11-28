#!/usr/bin/env ruby
require_relative '../scenarios/entry_model'
require 'optparse'

seed = 17
OptionParser.new { |p| p.on('--seed N', Integer) { |n| seed = n } }.parse!
Dir.mktmpdir('wayu-model') do |dir|
  model = EntryModel.new(dir, ENV.fetch('WAYU_BIN', 'bin/wayu'))
  begin
    model.setup
    model.sequence(seed)
    model.command('build')
    model.verify_shells
  rescue StandardError
    warn JSON.generate(model.diagnostics(seed))
    raise
  end
end
