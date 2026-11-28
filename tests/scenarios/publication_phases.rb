require 'timeout'
require 'io/nonblock'
require_relative 'entry_model'

module PublicationPhases
  def self.build(dir)
    path = File.join(dir, 'wayu-phase')
    raise 'instrumented build failed' unless system('odin', 'build', 'src', '-define:WAYU_TEST_PUBLICATION_PHASES=true', "-out:#{path}")
    path
  end

  def self.interrupt(binary, model, target, phase, name, instrumented: true, terminate: true)
    IO.pipe do |notice, notify|
      IO.pipe do |wait, resume|
        wait.nonblock = true
        env = model.env.merge('WAYU_TEST_TARGET' => File.join(model.data, target), 'WAYU_TEST_PHASE' => phase)
        pid = Process.spawn(env, binary, 'alias', 'add', name, 'echo interrupted',
                            3 => notify, 4 => wait, out: File::NULL, unsetenv_others: true)
        notify.close
        wait.close
        begin
          raise "timeout at #{phase} #{target}" unless IO.select([notice], nil, nil, 15)
          token = notice.read(1)
          raise "unexpected handshake #{token.inspect}" unless instrumented ? token == "\x01" : token.nil?
          if instrumented && terminate
            Process.kill('KILL', pid)
          elsif instrumented
            resume.write("\xa5")
            resume.flush
          end
          _, status = Timeout.timeout(15) { Process.wait2(pid) }
          pid = nil
          expected = instrumented && terminate ? status.termsig == Signal.list.fetch('KILL') : status.success?
          raise "unexpected exit #{status.inspect}" unless expected
        ensure
          if pid
            Process.kill('KILL', pid) rescue nil
            Process.wait(pid) rescue nil
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  WayuFixture.with_directory('wayu-phase-self') do |dir|
    model = EntryModel.new(dir, ENV.fetch('WAYU_BIN', 'bin/wayu'))
    model.setup
    PublicationPhases.interrupt(PublicationPhases.build(dir), model, 'entries.json', 'before', 'test_build', terminate: false)
    PublicationPhases.interrupt(File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu')), model, 'entries.json', 'before', 'ordinary', instrumented: false)
  end
end
