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
