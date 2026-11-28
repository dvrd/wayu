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
