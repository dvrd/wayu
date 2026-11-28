package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_pipeline_completion_requires_every_member :: proc(t: ^testing.T) {
	job: wayu.Native_Job
	defer delete(job.members)

	append(&job.members, wayu.Native_Process{state = .Done}, wayu.Native_Process{state = .Stopped})
	testing.expect(t, !wayu.native_job_done(&job))
	job.members[1].state = .Done
	testing.expect(t, wayu.native_job_done(&job))
}

@(test)
test_completed_job_eviction :: proc(t: ^testing.T) {
	s: wayu.Native_Session
	defer delete(s.jobs)

	defer delete(s.completed_jobs)

	for id in 1 ..= 257 {
		job := wayu.Native_Job {
			id    = id,
			group = auto_cast (1_000_000 + id),
		}

		append(&job.members, wayu.Native_Process{pid = job.group, state = .Done, status = 7})
		append(&s.jobs, job)
		wayu.native_jobs_reap(&s)
		testing.expect_value(t, len(s.completed_jobs), min(id, 256))
		testing.expect_value(t, s.completed_jobs[0].id, max(1, id - 255))
	}

	testing.expect_value(t, s.completed_jobs[255].id, 257)
}

@(private = "file")
add_test_job :: proc(s: ^wayu.Native_Session, id: int, running := false) {
	job := wayu.Native_Job {
		id    = id,
		group = auto_cast (1_000_000 + id),
	}

	member := wayu.Native_Process {
		pid    = job.group,
		state  = .Running if running else .Done,
		status = 0 if running else id % 100,
	}
	append(&job.members, member)
	append(&s.jobs, job)
}

// Completed results are counted on their own: running jobs neither use nor
// lose a slot, and a pass that completes more jobs than the limit keeps the
// newest results.
@(test)
test_completed_job_eviction_keeps_newest_results :: proc(t: ^testing.T) {
	s: wayu.Native_Session
	defer {
		for &job in s.jobs {wayu.native_job_destroy(&job)}

		delete(s.jobs)
		delete(s.completed_jobs)
	}

	for id in 1 ..= 3 {add_test_job(&s, id, running = true)}

	for id in 4 ..= 258 {add_test_job(&s, id)}

	wayu.native_jobs_reap(&s)
	testing.expect_value(t, len(s.completed_jobs), 255)
	add_test_job(&s, 259)
	wayu.native_jobs_reap(&s)
	testing.expect_value(t, len(s.completed_jobs), 256)
	testing.expect_value(t, s.completed_jobs[0].id, 4)

	// The 257th result evicts only the oldest one.
	add_test_job(&s, 260)
	wayu.native_jobs_reap(&s)
	testing.expect_value(t, len(s.completed_jobs), 256)
	testing.expect_value(t, s.completed_jobs[0].id, 5)
	testing.expect_value(t, s.completed_jobs[0].status, 5)
	testing.expect_value(t, s.completed_jobs[255].id, 260)
	testing.expect_value(t, s.completed_jobs[255].status, 60)

	for id in 261 ..= 560 {add_test_job(&s, id)}

	wayu.native_jobs_reap(&s)
	testing.expect_value(t, len(s.completed_jobs), 256)
	testing.expect_value(t, s.completed_jobs[0].id, 305)
	testing.expect_value(t, s.completed_jobs[255].id, 560)
	testing.expect_value(t, wayu.native_wait_target(&s, "%560"), 60)
	testing.expect_value(t, len(s.completed_jobs), 255)

	testing.expect_value(t, len(s.jobs), 3)
	for job, i in s.jobs {
		testing.expect_value(t, job.id, i + 1)
		testing.expect_value(t, job.members[0].state, .Running)
	}
}
