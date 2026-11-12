#!/usr/bin/env ruby
# Internal evidence for an outside reviewer; never labels itself an audit.
require 'digest'
require 'open3'
require 'time'

puts 'INTERNAL TEST EVIDENCE — independent security review remains pending'
puts "UTC: #{Time.now.utc.iso8601}"
puts "Commit: #{Open3.capture2('git', 'rev-parse', 'HEAD').first.strip}"
puts "Dirty: #{!Open3.capture2('git', 'status', '--porcelain').first.empty?}"
%w[secrets_store secrets_recipients age keystore atomic_io backup init_generator shell].each do |name|
  path = "src/#{name}.odin"
  puts "#{Digest::SHA256.file(path).hexdigest}  #{path}"
end
puts File.read('.github/odin-release').strip
if ARGV == ['--manifest-only']
  puts 'Source manifest only; use the accompanying CI job logs for test outcomes.'
  exit 0
end
abort 'Usage: security_evidence.rb [--manifest-only]' unless ARGV.empty?
abort 'Unit evidence failed' unless system('./build_it', 'test')
%w[test_secrets_store.rb test_secrets_multi.rb test_secrets.rb test_backup.rb].each do |file|
  abort "Integration evidence failed: #{file}" unless system({ 'WAYU_BIN' => File.expand_path('bin/wayu') }, 'ruby', "tests/integration/#{file}")
end
puts 'Internal evidence complete; assessor sign-off is a separate requirement.'
