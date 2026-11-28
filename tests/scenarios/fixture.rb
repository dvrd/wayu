require 'tmpdir'
require 'fileutils'

module WayuFixture
  def self.with_directory(prefix, parent = nil)
    path = Dir.mktmpdir(prefix, parent)
    begin
      yield path
    ensure
      remove(path)
    end
  end

  def self.remove(path)
    # An intentionally asynchronous zcompile can rename .tmp.zwc while
    # FileUtils walks the fixture. Force handles vanished entries; verify
    # the root really disappears and bound retries for newly created files.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      FileUtils.rm_rf(path)
      return unless File.exist?(path) || File.symlink?(path)
      raise "fixture cleanup did not finish: #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
  end
end
