#!/usr/bin/env ruby
# Evidence files must retain samples and fail closed on incomplete data.
require 'open3'
require 'tmpdir'
require 'json'
require 'fileutils'

root = Dir.mktmpdir('wayu-benchmark-report-')
begin
  binary = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
  zsh = ENV.fetch('PATH').split(':').map { |d| "#{d}/zsh" }.find { |f| File.executable?(f) }
  abort 'zsh is required' unless zsh
  metrics = %w[first_prompt_lag_ms first_command_lag_ms command_lag_ms input_lag_ms exit_time_ms]
  flags = %w[has_compsys has_autosuggestions has_syntax_highlighting]
  good = metrics.map { |m| "#{m}=( 1 3 )" }.join("\n") + "\n" + flags.map { |f| "#{f}=( 1 1 )" }.join("\n") + "\n"
  raw = "#{root}/fixture.raw"
  File.write(raw, good)
  File.write("#{root}/fixture.cold", '10.5')
  output = "#{root}/report.json"
  cmd = ['python3', 'tests/benchmark/report.py', '--results', root, '--output', output,
         '--binary', binary, '--zsh', zsh, '--iters', '2', '--pin', 'fixture=synthetic']
  out, status = Open3.capture2e(*cmd)
  abort out unless status.success?
  doc = JSON.parse(File.read(output))
  row = doc.fetch('results').fetch('fixture')
  abort 'report lost samples or metadata' unless row['median_ms'].values.all? { |v| v == 2 } &&
    row['samples_ms'].values.all? { |v| v == [1, 3] } && doc['binary_sha256'].size == 64 &&
    doc['pins']['fixture'] == 'synthetic' && row['cold_first_process_exit_ms'] == 10.5
  [good.sub('1 3', 'NaN 3'), good.sub('1 3', '1'), good.sub('has_compsys=( 1 1 )', 'has_compsys=( 1 )')].each do |bad|
    File.write(raw, bad)
    _, status = Open3.capture2e(*cmd)
    abort 'invalid benchmark samples were accepted' if status.success?
  end
  puts 'PASS benchmark report: samples, medians, provenance and invalid/incomplete data rejection (synthetic data only)'
ensure
  FileUtils.rm_rf(root)
end
