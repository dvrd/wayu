package wayu

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Native_Process :: struct {
	pid:    posix.pid_t,
	state:  enum {
		Running,
		Stopped,
		Done,
	},
	status: int,
}
Native_Job :: struct {
	id:        int,
	group:     posix.pid_t,
	members:   [dynamic]Native_Process,
	name:      string,
	modes:     posix.termios,
	has_modes: bool,
}

native_job_destroy :: proc(job: ^Native_Job) {
	delete(job.members)
	delete(job.name)
}

native_job_update :: proc(job: ^Native_Job, block: bool) {
	for {
		running := false
		for m in job.members {
			if m.state == .Running {
				running = true
				break
			}
		}
		if block && !running {
			return
		}
		flags := posix.Wait_Flags{.UNTRACED, .CONTINUED}
		if !block {
			flags += {.NOHANG}
		}
		status: c.int
		pid := posix.waitpid(-job.group, &status, flags)
		if pid < 0 && posix.errno() == .EINTR {
			continue
		}
		if pid <= 0 {
			return
		}
		for &m in job.members {
			if m.pid != pid {
				continue
			}
			if posix.WIFSTOPPED(status) {
				m.state = .Stopped
				m.status = 128 + int(posix.WSTOPSIG(status))
			} else if posix.WIFCONTINUED(status) {
				m.state = .Running
			} else {
				m.state = .Done
				m.status =
					int(posix.WEXITSTATUS(status)) if \
						posix.WIFEXITED(status) else \
						128 + int(posix.WTERMSIG(status))
			}
			break
		}
	}
}

native_job_done :: proc(job: ^Native_Job) -> bool {
	for m in job.members {
		if m.state != .Done {
			return false
		}
	}
	return true
}

native_job_resume :: proc(job: ^Native_Job) -> bool {
	if posix.killpg(job.group, .SIGCONT) != .OK {
		return false
	}
	for &m in job.members {
		if m.state == .Stopped {
			m.state = .Running
		}
	}
	return true
}

native_job_wait :: proc(s: ^Native_Session, job: ^Native_Job, resume: bool) -> int {
	if s.terminal {
		if resume && posix.tcsetpgrp(0, job.group) != .OK {
			fmt.eprintln("wayu: cannot give job the terminal")
			return 1
		}
		if resume && job.has_modes {
			posix.tcsetattr(0, .TCSANOW, &job.modes)
		}
	}
	defer if s.terminal {
		posix.tcsetpgrp(0, posix.getpgrp())
		posix.tcsetattr(0, .TCSANOW, &s.modes)
	}
	if resume && !native_job_resume(job) {
		return 1
	}
	native_job_update(job, true)
	if s.terminal && !native_job_done(job) {
		job.has_modes = posix.tcgetattr(0, &job.modes) == .OK
	}
	return job.members[len(job.members) - 1].status
}

native_jobs_reap :: proc(s: ^Native_Session) {
	for i := len(s.jobs) - 1; i >= 0; i -= 1 {
		job := &s.jobs[i]
		native_job_update(job, false)
		if native_job_done(job) {
			native_job_destroy(job)
			ordered_remove(&s.jobs, i)
		}
	}
}

native_jobs_command :: proc(s: ^Native_Session, args: []string) -> int {
	native_jobs_reap(s)
	if args[0] == "jobs" {
		if len(args) != 1 {
			return EXIT_USAGE
		}
		for job in s.jobs {
			running := false
			for m in job.members {
				if m.state == .Running {
					running = true
				}
			}
			fmt.printfln("[%d] %s %s", job.id, "Running" if running else "Stopped", job.name)
		}
		return 0
	}
	if len(args) > 2 {
		return EXIT_USAGE
	}
	idx := len(s.jobs) - 1
	if len(args) == 2 {
		id, ok := strconv.parse_int(strings.trim_prefix(args[1], "%"))
		idx = -1
		if ok {
			for job, i in s.jobs {
				if job.id == id {
					idx = i
					break
				}
			}
		}
	}
	if idx < 0 {
		fmt.eprintfln("%s: no such job", args[0])
		return 1
	}
	job := &s.jobs[idx]
	if args[0] == "bg" {
		return 0 if native_job_resume(job) else 1
	}
	rc := native_job_wait(s, job, true)
	if native_job_done(job) {
		native_job_destroy(job)
		ordered_remove(&s.jobs, idx)
	}
	return rc
}
