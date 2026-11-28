package wayu

import "base:intrinsics"
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
	signal: posix.Signal,
}
Native_Job :: struct {
	id:                   int,
	group:                posix.pid_t,
	shared_capture_group: bool,
	members:              [dynamic]Native_Process,
	name:                 string,
	modes:                posix.termios,
	has_modes:            bool,
}

native_job_destroy :: proc(job: ^Native_Job) {
	delete(job.members)
	delete(job.name)
}

native_job_update :: proc(job: ^Native_Job, block: bool, interruptible := false) {
	for {
		if interruptible && intrinsics.volatile_load(&native_interrupted) {
			return
		}

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
		// Background jobs inside a substitution share its cancellation group. A
		// group-wide wait could consume the status of a different job.
		if job.shared_capture_group {
			for &member in job.members {
				if member.state != .Running {
					continue
				}

				status: c.int
				pid := posix.waitpid(member.pid, &status, flags)
				if pid < 0 && posix.errno() == .EINTR {
					continue
				}

				if pid == member.pid {
					native_process_status(&member, status)
				}

				if block && pid < 0 {
					return
				}
			}

			if !block {
				return
			}

			continue
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
			native_process_status(&m, status)

			break
		}
	}
}

native_process_status :: proc(m: ^Native_Process, status: c.int) {
	// The pinned Linux WIFSIGNALED predicate also accepts wait status zero.
	// Decode an ordinary exit first, including an explicit exit 128 + signal.
	if posix.WIFEXITED(status) {
		m.state = .Done
		m.signal = nil
		m.status = int(posix.WEXITSTATUS(status))
	} else if posix.WIFCONTINUED(status) {
		m.state = .Running
		m.status = 0
	} else if posix.WIFSTOPPED(status) {
		m.state = .Stopped
		m.status = 128 + int(posix.WSTOPSIG(status))
	} else {
		m.state = .Done
		m.signal = posix.WTERMSIG(status)
		m.status = 128 + int(m.signal)
	}
}

native_job_status :: proc(job: ^Native_Job, failed_stage: ^int = nil) -> int {
	#reverse for member, stage in job.members {
		// A downstream reader may have finished successfully before its producer.
		if member.status == 0 || (stage + 1 < len(job.members) && member.signal == .SIGPIPE) {
			continue
		}

		if failed_stage != nil {
			failed_stage^ = stage
		}

		return member.status
	}

	return 0
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

native_job_wait :: proc(
	s: ^Native_Session,
	job: ^Native_Job,
	resume: bool,
	failed_stage: ^int = nil,
) -> int {
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
	if s.terminal {
		for member in job.members {
			if member.signal == .SIGINT {
				native_interrupt(.SIGINT)
				break
			}
		}
	}

	return native_job_status(job, failed_stage)
}

Native_Job_Result :: struct {
	id:     int,
	pid:    posix.pid_t,
	status: int,
}

NATIVE_COMPLETED_JOB_LIMIT :: 256

native_jobs_reap :: proc(s: ^Native_Session) {
	for i := len(s.jobs) - 1; i >= 0; i -= 1 {
		job := &s.jobs[i]
		native_job_update(job, false)
		if native_job_done(job) {
			last := job.members[len(job.members) - 1]
			if len(s.completed_jobs) == NATIVE_COMPLETED_JOB_LIMIT {
				ordered_remove(&s.completed_jobs, 0)
			}

			append(&s.completed_jobs, Native_Job_Result{job.id, last.pid, native_job_status(job)})
			native_job_destroy(job)
			ordered_remove(&s.jobs, i)
		}
	}
}

native_wait_target :: proc(s: ^Native_Session, target: string) -> int {
	by_id := strings.has_prefix(target, "%")
	digits := strings.trim_prefix(target, "%")
	for digit in digits {
		if digit < '0' || digit > '9' {
			fmt.eprintln("usage: wait [PID | %JOB]...")
			return EXIT_USAGE
		}
	}

	number, ok := strconv.parse_int(digits, 10)
	if !ok || number <= 0 {
		fmt.eprintln("usage: wait [PID | %JOB]...")
		return EXIT_USAGE
	}

	for &job, i in s.jobs {
		last := &job.members[len(job.members) - 1]
		key := job.id if by_id else int(last.pid)
		if key != number {
			continue
		}

		native_job_update(&job, true, s.terminal)
		if s.terminal && intrinsics.volatile_load(&native_interrupted) {
			return 130
		}

		if !native_job_done(&job) {
			return 1
		}

		status := native_job_status(&job)
		native_job_destroy(&job)
		ordered_remove(&s.jobs, i)
		return status
	}

	#reverse for result, i in s.completed_jobs {
		key := result.id if by_id else int(result.pid)
		if key == number {
			ordered_remove(&s.completed_jobs, i)
			return result.status
		}
	}

	fmt.eprintfln("wait: %s: no such background job", target)
	return EXIT_EXEC_NOT_FOUND
}

native_jobs_command :: proc(s: ^Native_Session, args: []string) -> int {
	native_jobs_reap(s)
	if args[0] == "wait" {
		if len(args) > 1 {
			result := 0
			for target in args[1:] {
				result = native_wait_target(s, target)
				if s.terminal && intrinsics.volatile_load(&native_interrupted) {
					break
				}
			}

			return result
		}

		result := 0
		for &job in s.jobs {
			native_job_update(&job, true, s.terminal)
			if s.terminal && intrinsics.volatile_load(&native_interrupted) {
				return 130
			}

			if !native_job_done(&job) {
				result = 1
			}
		}

		native_jobs_reap(s)
		clear(&s.completed_jobs)
		return result
	}

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
