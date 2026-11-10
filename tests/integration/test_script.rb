#!/usr/bin/env ruby
# Integration tests for `wayu script` (new/edit/list/remove/import/build).
#
# A fake `swiftc` (and `swift`) on PATH writes an executable shell stub, so
# the compiled path runs on CI without Swift; a real swiftc is never used.

require 'open3'
require 'fileutils'
require 'json'
require_relative 'test_helper'

class ScriptIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "📜 Testing script command integration..."
    puts

    begin
      build_project
      initialize_wayu(shell: 'zsh')
      setup_fakes

      test_list_empty
      test_new_interpreted
      test_new_swift_compiled
      test_new_errors
      test_default_lang_from_toml
      test_edit_rebuilds
      test_stale_and_build
      test_failed_build_keeps_binary
      test_edit_during_compile_stays_stale
      test_new_editor_can_run_wayu
      test_prompt_hook_build_compiles_in_background
      test_import_dry_run
      test_import
      test_import_copy_and_duplicate
      test_remove
      test_doctor_dangling_bin
      test_duplicate_names
      test_crlf_scripts
      test_build_header
      test_path_in_shells
      test_live_path_sync
      test_functions_in_data_dir
    ensure
      teardown_test_env
    end

    print_summary("script")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def scripts_dir; "#{@data_dir}/scripts"; end
  def bin_dir; "#{@data_dir}/bin"; end

  def setup_fakes
    @fakebin = "#{@scratch}/fakebin"
    FileUtils.mkdir_p(@fakebin)
    File.write("#{@fakebin}/swiftc", <<~SH)
      #!/bin/sh
      # fake swiftc: [-O] -o OUT SRC
      out=; src=
      while [ $# -gt 0 ]; do
        case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) src=$1; shift ;; esac
      done
      if grep -q COMPILE_ERROR "$src"; then echo "error: fake compile error" >&2; exit 1; fi
      if grep -q SLOW_COMPILE "$src"; then sleep 3; fi
      n=$(grep -c . "$src")
      # MUTATE: the source is saved again while the compiler runs.
      if grep -q MUTATE "$src"; then echo '// saved mid-build' >> "$src"; fi
      printf '#!/bin/sh\\necho "compiled %s lines=%s"\\n' "$(basename "$src")" "$n" > "$out"
      chmod +x "$out"
    SH
    File.write("#{@fakebin}/swift", "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, ["#{@fakebin}/swiftc", "#{@fakebin}/swift"])
    # An "editor" that appends a line (edit → rebuild).
    @append_editor = "#{@scratch}/append-editor"
    File.write(@append_editor, "#!/bin/sh\necho '// edited' >> \"$1\"\n")
    FileUtils.chmod(0o755, @append_editor)
  end

  def env(extra = {})
    ENV.to_h.merge('HOME' => @tmp_home, 'EDITOR' => '/usr/bin/true',
                   'PATH' => "#{@fakebin}:#{ENV['PATH']}").merge(extra)
  end

  def run_s(args, extra = {})
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env(extra), "#{@wayu_bin} #{args}", chdir: project_root, stdin_data: '')
    [(stdout + stderr).force_encoding('UTF-8'), status]
  end

  def list_json
    out, st = run_s('script list --json')
    return {} unless st.success?
    JSON.parse(out)['scripts'].to_h { |s| [s['name'], s] }
  rescue JSON::ParserError
    {}
  end

  def check(label, condition, detail = nil)
    print "#{label}... "
    if condition
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}" if detail
      @failed += 1
    end
  end

  def test_list_empty
    out, st = run_s('script list')
    json, jst = run_s('scripts ls --json')
    check('list with no scripts', st.success? && out.include?('No scripts') && jst.success? &&
          JSON.parse(json) == { 'scripts' => [], 'count' => 0 }, "#{out} #{json}")
  end

  def test_new_interpreted
    out, st = run_s('script new hello --lang sh')
    src = "#{scripts_dir}/hello.sh"
    shebang = File.exist?(src) ? File.readlines(src).first.strip : ''
    mode = File.exist?(src) ? File.stat(src).mode & 0o777 : 0
    link = File.symlink?("#{bin_dir}/hello") ? File.readlink("#{bin_dir}/hello") : nil
    run_out, = Open3.capture2e("#{bin_dir}/hello")
    check('new --lang sh: source 0755 with absolute shebang, relative bin symlink, runs',
          st.success? && shebang.match?(%r{\A#!/\S*/sh\z}) && mode == 0o755 &&
          link == '../scripts/hello.sh' && run_out.strip == 'hello',
          "exit=#{st.exitstatus} shebang=#{shebang} mode=#{mode.to_s(8)} link=#{link} run=#{run_out} out=#{out}")
  end

  def test_new_swift_compiled
    out, st = run_s('script new sw')
    src = "#{scripts_dir}/sw.swift"
    shebang = File.exist?(src) ? File.readlines(src).first.strip : ''
    run_out, = Open3.capture2e("#{bin_dir}/sw")
    info = list_json['sw'] || {}
    check('new (default swift): compiled with swiftc into bin/, shebang = swift on PATH',
          st.success? && shebang == "#!#{@fakebin}/swift" && File.file?("#{bin_dir}/sw") &&
          !File.symlink?("#{bin_dir}/sw") && run_out.include?('compiled sw.swift') &&
          info['lang'] == 'swift' && info['compiled'] == true && info['stale'] == false &&
          info['source'] == src && info['bin'] == "#{bin_dir}/sw",
          "exit=#{st.exitstatus} shebang=#{shebang} run=#{run_out} info=#{info} out=#{out}")
  end

  def test_new_errors
    _, dup = run_s('script new hello --lang sh')
    _, badlang = run_s('script new x --lang cobol')
    _, badname = run_s("script new 'bad name' --lang sh")
    out, nocomp = run_s('script new nos --lang swift', 'PATH' => '/nonexistent')
    _, noname = run_s('script new')
    _, dry = run_s('--dry-run script new drynew --lang sh')
    check('new: existing 65, bad --lang 64, bad name 65, missing compiler 69, no name 64, dry-run writes nothing',
          dup.exitstatus == 65 && badlang.exitstatus == 64 && badname.exitstatus == 65 &&
          nocomp.exitstatus == 69 && out.include?('swiftc') && noname.exitstatus == 64 &&
          dry.success? && Dir.glob("#{scripts_dir}/drynew*").empty? && !File.exist?("#{scripts_dir}/nos.swift"),
          "dup=#{dup.exitstatus} badlang=#{badlang.exitstatus} badname=#{badname.exitstatus} nocomp=#{nocomp.exitstatus} noname=#{noname.exitstatus} out=#{out}")
  end

  def test_default_lang_from_toml
    toml = "#{@config_dir}/wayu.toml"
    original = File.read(toml)
    File.write(toml, original + "\n[scripts]\ndefault_lang = \"python\"\n")
    _, valid = run_s('toml validate')
    _, st = run_s('script new pyd')
    py = File.exist?("#{scripts_dir}/pyd.py")
    File.write(toml, original + "\n[scripts]\ndefault_lang = \"cobol\"\n")
    vout, invalid = run_s('toml validate')
    _, newbad = run_s('script new cob')
    File.write(toml, original)
    check('[scripts] default_lang picks the language; an unknown one fails validate (65) and new (78)',
          valid.success? && st.success? && py && invalid.exitstatus == 65 && vout.include?('cobol') &&
          newbad.exitstatus == 78,
          "valid=#{valid.exitstatus} new=#{st.exitstatus} py=#{py} invalid=#{invalid.exitstatus} newbad=#{newbad.exitstatus} #{vout}")
  end

  def test_edit_rebuilds
    _, st = run_s('script edit sw', 'EDITOR' => @append_editor)
    run_out, = Open3.capture2e("#{bin_dir}/sw")
    _, missing = run_s('script edit nope')
    check('edit opens $EDITOR and rebuilds; unknown name exits 65',
          st.success? && File.read("#{scripts_dir}/sw.swift").include?('// edited') &&
          run_out.include?('lines=4') && list_json.dig('sw', 'stale') == false && missing.exitstatus == 65,
          "exit=#{st.exitstatus} run=#{run_out} missing=#{missing.exitstatus}")
  end

  def test_stale_and_build
    File.write("#{scripts_dir}/sw.swift", "print(1)\nprint(2)\nprint(3)\nprint(4)\nprint(5)\n")
    stale = list_json.dig('sw', 'stale')
    _, st = run_s('build')
    run_out, = Open3.capture2e("#{bin_dir}/sw")
    after = list_json.dig('sw', 'stale')
    File.write("#{scripts_dir}/sw.swift", "print(1)\n")
    _, bst = run_s('script build')
    run2, = Open3.capture2e("#{bin_dir}/sw")
    check('a changed source is stale; `wayu build` and `script build` rebuild it',
          stale == true && st.success? && run_out.include?('lines=5') && after == false &&
          bst.success? && run2.include?('lines=1'),
          "stale=#{stale} build=#{st.exitstatus} run=#{run_out} after=#{after} sb=#{bst.exitstatus} run2=#{run2}")
  end

  def test_failed_build_keeps_binary
    File.write("#{scripts_dir}/sw.swift", "COMPILE_ERROR\n")
    out, st = run_s('script build sw')
    run_out, = Open3.capture2e("#{bin_dir}/sw")
    File.write("#{scripts_dir}/sw.swift", "print(1)\n")
    run_s('script build sw')
    check('a failed compile prints the compiler error, exits 1, keeps the old binary',
          st.exitstatus == 1 && out.include?('fake compile error') && run_out.include?('lines=1'),
          "exit=#{st.exitstatus} out=#{out} run=#{run_out}")
  end

  # Regression (OKAMI-311): the hash was taken after the compile, so a
  # save during the compile was recorded as built and never rebuilt.
  def test_edit_during_compile_stays_stale
    File.write("#{scripts_dir}/sw.swift", "// MUTATE\nprint(1)\n")
    _, st = run_s('script build sw')
    stale = list_json.dig('sw', 'stale')
    File.write("#{scripts_dir}/sw.swift", "print(1)\n")
    run_s('script build sw')
    check('a source saved during the compile stays stale after the build',
          st.success? && stale == true, "exit=#{st.exitstatus} stale=#{stale.inspect}")
  end

  # Regression (OKAMI-307): `script new` held the config lock while $EDITOR
  # ran, so an editor that runs wayu (or stays open) blocked every write.
  def test_new_editor_can_run_wayu
    editor = "#{@scratch}/wayu-editor"
    File.write(editor, "#!/bin/sh\n\"#{@wayu_bin}\" const add EDITOR_PROBE 1 >/dev/null 2>&1\n")
    FileUtils.chmod(0o755, editor)
    full = env('EDITOR' => editor)
    project_root = File.expand_path('../..', __dir__)
    status = nil
    Open3.popen3(full, "#{@wayu_bin} script new edlock --lang bash", chdir: project_root, pgroup: true) do |i, o, e, w|
      i.close
      out_t = Thread.new { o.read }
      err_t = Thread.new { e.read }
      unless w.join(20)
        Process.kill('KILL', -w.pid) rescue nil
        w.join
      else
        status = w.value
      end
      out_t.value; err_t.value
    end
    store = File.exist?("#{@data_dir}/entries.json") ? File.read("#{@data_dir}/entries.json") : ''
    run_s('script remove edlock --yes')
    run_s('const rm EDITOR_PROBE')
    check('script new: an $EDITOR that runs wayu completes (no lock held during the editor)',
          status&.success? && store.include?('EDITOR_PROBE'), "status=#{status.inspect}")
  end

  # OKAMI-308: the prompt hook's `wayu build` (WAYU_PROMPT_HOOK=1) doesn't
  # wait for a compiler; the stale script is built in the background.
  def test_prompt_hook_build_compiles_in_background
    File.write("#{scripts_dir}/sw.swift", "// SLOW_COMPILE\nprint(1)\nprint(2)\n")
    t0 = Time.now
    _, st = run_s('build', 'WAYU_PROMPT_HOOK' => '1')
    elapsed = Time.now - t0
    stale_after = list_json.dig('sw', 'stale')
    built = false
    40.times do
      break if (built = list_json.dig('sw', 'stale') == false)
      sleep 0.25
    end
    run_out, = Open3.capture2e("#{bin_dir}/sw")
    core = File.read("#{@data_dir}/core.zsh")
    check('the prompt hook build returns before the compile; it runs in the background',
          st.success? && elapsed < 2.5 && stale_after == true && built && run_out.include?('lines=3') &&
          core.include?('WAYU_PROMPT_HOOK=1 command "${_WAYU_BIN:-wayu}" build'),
          "exit=#{st.exitstatus} elapsed=#{elapsed.round(2)} stale_after=#{stale_after} built=#{built} run=#{run_out}")
  end

  def import_fixtures(dir)
    FileUtils.mkdir_p(dir)
    w = ->(name, body) { File.binwrite("#{dir}/#{name}", body) }
    w.('greet.swift', "#!/usr/bin/swift\nprint(\"hi\")\n")
    w.('ba', "#!/bin/bash\necho bash-a\n")
    w.('rb', "#!/usr/bin/ruby\nputs 1\n")
    w.('zz', "#!/usr/bin/env zsh\necho zz\n")
    w.('tsy', "#!/Users/someone/.bun/bin/bun\nconsole.log(1)\n")
    w.('launch', "#!/bin/sh\nexec \"/abs/path/app/bin/tool\" \"$@\"\n")
    w.('black', "#!/Users/someone/.local/pipx/venvs/black/bin/python\nimport black\n")
    w.('stub', "#!/opt/py/bin/python3\nimport re\nimport sys\nfrom foo.cli import main\n" \
               "if __name__ == '__main__':\n    sys.exit(main())\n")
    w.('elf', "\x7fELF\x02\x01\x00\x00binary")
    w.('README', "hello\n")
    w.('hello', "#!/bin/sh\necho clash\n")
    File.symlink("#{dir}/ba", "#{dir}/link")
  end

  def test_import_dry_run
    dir = "#{@scratch}/imp-dry"
    import_fixtures(dir)
    before = Dir.children(dir).sort
    out, st = run_s("--dry-run script import #{dir}/*")
    check('import --dry-run lists import/skip and changes nothing',
          st.success? && Dir.children(dir).sort == before && !File.exist?("#{scripts_dir}/ba.bash") &&
          out.include?('launcher for /abs/path/app/bin/tool') && out.include?('symlink'),
          "exit=#{st.exitstatus} out=#{out}")
  end

  def test_import
    dir = "#{@scratch}/imp"
    import_fixtures(dir)
    out, st = run_s("script import #{dir}/*")
    imported = %w[greet ba rb zz tsy]
    skipped = {
      'launch' => 'launcher for /abs/path/app/bin/tool', 'black' => 'package manager',
      'stub' => 'console_scripts', 'elf' => 'binary', 'README' => 'no shebang',
      'hello' => 'already exists', 'link' => 'symlink'
    }
    files_ok = imported.all? { |n| File.exist?("#{bin_dir}/#{n}") } &&
               File.exist?("#{scripts_dir}/ba.bash") && File.exist?("#{scripts_dir}/rb.rb") &&
               File.exist?("#{scripts_dir}/zz.zsh") && File.exist?("#{scripts_dir}/tsy.ts") &&
               File.exist?("#{scripts_dir}/greet.swift")
    # Moved: originals of imported files are gone, skipped ones stay.
    moved_ok = imported.none? { |n| File.exist?("#{dir}/#{n}") || File.exist?("#{dir}/#{n}.swift") } &&
               skipped.keys.all? { |n| File.exist?("#{dir}/#{n}") || File.symlink?("#{dir}/#{n}") }
    reasons_ok = skipped.all? { |n, why| out.lines.any? { |l| l.include?("#{dir}/#{n}:") && l.include?(why) } }
    shebangs_ok = File.readlines("#{scripts_dir}/rb.rb").first.strip == '#!/usr/bin/ruby' &&
                  File.readlines("#{scripts_dir}/zz.zsh").first.strip == '#!/usr/bin/env zsh' &&
                  File.readlines("#{scripts_dir}/tsy.ts").first.strip == '#!/Users/someone/.bun/bin/bun'
    run_ba, = Open3.capture2e("#{bin_dir}/ba")
    run_greet, = Open3.capture2e("#{bin_dir}/greet")
    langs = list_json
    check('import moves scripts in (shebang kept, swift compiled) and skips launchers/binaries/symlinks/dupes',
          st.success? && out.include?('Imported 5, skipped 7') && files_ok && moved_ok && reasons_ok &&
          shebangs_ok && run_ba.strip == 'bash-a' && run_greet.include?('compiled greet.swift') &&
          langs.dig('tsy', 'lang') == 'bun' && langs.dig('zz', 'lang') == 'zsh' && langs.dig('greet', 'compiled') == true,
          "exit=#{st.exitstatus} files=#{files_ok} moved=#{moved_ok} reasons=#{reasons_ok} shebangs=#{shebangs_ok} out=#{out}")
  end

  def test_import_copy_and_duplicate
    dir = "#{@scratch}/imp-copy"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/cp.sh", "#!/bin/sh\necho cp\n")
    _, st = run_s("script import --copy #{dir}/cp.sh")
    out, again = run_s("script import --copy #{dir}/cp.sh")
    _, none = run_s('script import')
    check('import --copy keeps the original; re-import skips it (65 when nothing imported); no file 64',
          st.success? && File.exist?("#{dir}/cp.sh") && File.symlink?("#{bin_dir}/cp") &&
          again.exitstatus == 65 && out.include?('already exists') && none.exitstatus == 64,
          "copy=#{st.exitstatus} again=#{again.exitstatus} none=#{none.exitstatus} out=#{out}")
  end

  def test_remove
    _, noyes = run_s('script remove cp')
    _, dry = run_s('--dry-run script rm cp --yes')
    kept = File.exist?("#{scripts_dir}/cp.sh") && File.symlink?("#{bin_dir}/cp")
    _, st = run_s('script rm cp --yes')
    _, sw = run_s('script rm sw --yes')
    _, missing = run_s('script rm nope --yes')
    check('remove needs --yes (64), honors --dry-run, deletes source + bin (and hash), unknown 65',
          noyes.exitstatus == 64 && dry.success? && kept && st.success? &&
          !File.exist?("#{scripts_dir}/cp.sh") && !File.symlink?("#{bin_dir}/cp") &&
          sw.success? && !File.exist?("#{bin_dir}/sw") && !File.exist?("#{bin_dir}/.sw.hash") &&
          missing.exitstatus == 65,
          "noyes=#{noyes.exitstatus} dry=#{dry.exitstatus} kept=#{kept} rm=#{st.exitstatus} sw=#{sw.exitstatus} missing=#{missing.exitstatus}")
  end

  # OKAMI-339: a bin/ entry without a script is a fixable warning; `script
  # rm NAME --yes` and `doctor --fix --yes` remove it.
  def test_doctor_dangling_bin
    File.write("#{bin_dir}/orphan", "#!/bin/sh\n")
    out, = run_s('doctor --json')
    found = JSON.parse(out)['checks'].find { |c| c['name'] == 'script bin entries' } rescue nil
    _, noyes = run_s('script rm orphan')
    _, rm = run_s('script rm orphan --yes')
    rm_gone = !File.exist?("#{bin_dir}/orphan")
    File.symlink('../scripts/gone.sh', "#{bin_dir}/orphan2")
    fix_out, = run_s('doctor --fix --yes')
    fix_gone = !File.symlink?("#{bin_dir}/orphan2")
    check('doctor warns about a bin entry without a script; script rm / doctor --fix remove it',
          found && found['status'] == 'warning' && found['message'].include?('orphan') &&
          noyes.exitstatus == 64 && rm.success? && rm_gone && fix_gone,
          "check=#{found.inspect} noyes=#{noyes.exitstatus} rm=#{rm.exitstatus} rm_gone=#{rm_gone} fix_gone=#{fix_gone} fix=#{fix_out}")
  end

  # OKAMI-339: two sources for one name: building refuses (no flapping link),
  # edit/build by name exit 65, doctor reports an error; new/import refuse
  # the name.
  def test_duplicate_names
    File.write("#{scripts_dir}/dup.sh", "#!/bin/sh\necho sh\n")
    File.write("#{scripts_dir}/dup.rb", "#!/usr/bin/ruby\nputs 1\n")
    _, build = run_s('script build')
    link = File.symlink?("#{bin_dir}/dup")
    _, named = run_s('script build dup')
    doc, = run_s('doctor --json')
    found = JSON.parse(doc)['checks'].find { |c| c['name'] == 'scripts' } rescue nil
    _, new_st = run_s('script new dup --lang sh')
    imp = "#{@scratch}/dupimp"
    FileUtils.mkdir_p(imp)
    File.write("#{imp}/dup.py", "#!/usr/bin/env python3\nprint(1)\n")
    imp_out, imp_st = run_s("script import #{imp}/dup.py")
    FileUtils.rm_f(["#{scripts_dir}/dup.sh", "#{scripts_dir}/dup.rb", "#{bin_dir}/dup"])
    check('duplicate script names: no build, 65 by name, doctor error, new/import refused',
          build.exitstatus == 1 && !link && named.exitstatus == 65 &&
          found && found['status'] == 'error' && found['message'].include?("claim 'dup'") &&
          new_st.exitstatus == 65 && imp_st.exitstatus == 65 && imp_out.include?('already exists'),
          "build=#{build.exitstatus} link=#{link} named=#{named.exitstatus} doctor=#{found.inspect} new=#{new_st.exitstatus} imp=#{imp_st.exitstatus} #{imp_out}")
  end

  # OKAMI-338: import converts a CRLF script to LF (it runs); a CRLF source
  # placed by hand is not linked and doctor reports it.
  def test_crlf_scripts
    dir = "#{@scratch}/crlf"
    FileUtils.mkdir_p(dir)
    File.binwrite("#{dir}/crl.sh", "#!/bin/sh\r\necho crlf-ok\r\n")
    out, st = run_s("script import #{dir}/crl.sh")
    content = File.binread("#{scripts_dir}/crl.sh") rescue ''
    run_out, = Open3.capture2e("#{bin_dir}/crl")
    File.binwrite("#{scripts_dir}/hand.sh", "#!/bin/sh\r\necho hand\r\n")
    bout, bst = run_s('script build hand')
    doc, = run_s('doctor --json')
    found = JSON.parse(doc)['checks'].find { |c| c['name'] == 'scripts' } rescue nil
    FileUtils.rm_f(["#{scripts_dir}/hand.sh", "#{scripts_dir}/crl.sh", "#{bin_dir}/crl"])
    check('CRLF: import converts to LF and runs; hand-placed CRLF refused by build + doctor error',
          st.success? && out.include?('CRLF') && !content.include?("\r") && run_out.strip == 'crlf-ok' &&
          bst.exitstatus == 1 && bout.include?('CRLF') && !File.symlink?("#{bin_dir}/hand") &&
          found && found['status'] == 'error' && found['message'].include?('hand: CRLF'),
          "import=#{st.exitstatus} #{out} run=#{run_out} build=#{bst.exitstatus} #{bout} doctor=#{found.inspect}")
  end

  # OKAMI-369: a `wayu: build =` header builds any language; the output
  # becomes bin/NAME and edits rebuild it.
  def test_build_header
    File.write("#{@fakebin}/fakecc", <<~SH)
      #!/bin/sh
      # fakecc -o OUT SRC
      printf '#!/bin/sh\\necho "cc %s"\\n' "$(basename "$3")" > "$2"; chmod +x "$2"
    SH
    FileUtils.chmod(0o755, "#{@fakebin}/fakecc")
    File.write("#{scripts_dir}/hdr.c", "// wayu: build = fakecc -o {out} {src}\nint main(void) { return 0; }\n")
    _, st = run_s('script build')
    run_out, = Open3.capture2e("#{bin_dir}/hdr")
    info = list_json['hdr']
    File.write("#{scripts_dir}/hdr.c", "// wayu: build = fakecc -o {out} {src}\nint main(void) { return 1; }\n")
    stale = list_json.dig('hdr', 'stale')
    _, rm = run_s('script rm hdr --yes')
    check('build header: any language compiles with its own command, staleness tracked',
          st.success? && run_out.strip == 'cc hdr.c' && info && info['compiled'] == true &&
          info['stale'] == false && stale == true && rm.success?,
          "build=#{st.exitstatus} run=#{run_out} info=#{info.inspect} stale=#{stale}")
  end

  def test_path_in_shells
    results = %w[zsh bash fish].map do |sh|
      shell = `command -v #{sh} 2>/dev/null`.strip
      next [sh, true] if shell.empty?
      run_s("init --shell #{sh}")
      first = sh == 'fish' ? 'echo $PATH[1]' : 'echo "${PATH%%:*}"'
      out, = Open3.capture2e({ 'HOME' => @tmp_home, 'PATH' => '/usr/bin:/bin' }, shell, '-c',
                             %(source "#{@data_dir}/init.#{sh}" >/dev/null 2>&1; #{first}; hello))
      [sh, out.lines.map(&:strip) == [bin_dir, 'hello'], out]
    end
    check('core.zsh/bash/fish put <data>/bin first on PATH; scripts run by name',
          results.all? { |r| r[1] }, results.inspect)
  end

  # A shell opened before the first script picks <data>/bin up at its next
  # prompt (the PATH signature changes when bin/ gets its first entry).
  def test_live_path_sync
    unless system('command -v zsh >/dev/null 2>&1')
      print "live PATH sync... "
      puts "⊘ (zsh unavailable, skipped)"
      return
    end
    home = "#{@scratch}/live"
    FileUtils.mkdir_p(home)
    e = env('HOME' => home)
    Open3.capture2e(e, @wayu_bin, 'init', '--shell', 'zsh', stdin_data: '')
    script = %(source "#{home}/.local/share/wayu/init.zsh" >/dev/null 2>&1
      before=$(command -v live1 || echo none)
      "#{@wayu_bin}" script new live1 --lang sh </dev/null >/dev/null 2>&1
      _wayu_paths_sync
      echo "$before $(command -v live1 || echo none)")
    out, = Open3.capture2e(e.merge('PATH' => "#{@fakebin}:/usr/bin:/bin"), 'zsh', '-c', script)
    check('an open zsh gets <data>/bin on PATH at the next prompt after the first script',
          out.strip == "none #{home}/.local/share/wayu/bin/live1", "out=#{out}")
  end

  def test_functions_in_data_dir
    data = "#{@scratch}/data-split"
    e = { 'WAYU_DATA_DIR' => data }
    run_s('init --shell zsh', e)
    _, st = run_s('function add splitfn', e)
    check('functions/ lives in the data dir (WAYU_DATA_DIR), not the config dir',
          st.success? && File.exist?("#{data}/functions/splitfn.zsh") &&
          !File.exist?("#{@config_dir}/functions/splitfn.zsh"),
          "exit=#{st.exitstatus}")
  end
end

if __FILE__ == $0
  ScriptIntegrationTest.new.run
end
