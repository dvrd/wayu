#!/usr/bin/env ruby
# Compatibility entry point for the Odin integration runner.
Dir.chdir(File.expand_path('../..', __dir__)) { exec('./build_it', 'integration', *ARGV) }
