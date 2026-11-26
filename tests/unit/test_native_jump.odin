package test_wayu

import wayu "../../src"
import "core:testing"
import "core:time"

@(test)
test_native_jump_ranking :: proc(t: ^testing.T) {
	hour := i64(time.Hour)
	now := 200 * hour
	for c in ([]struct {
			age:   i64,
			score: f64,
		} {
			{-1, 16},
			{hour - 1, 16},
			{hour, 8},
			{24 * hour - 1, 8},
			{24 * hour, 2},
			{168 * hour - 1, 2},
			{168 * hour, 1},
		}) {
		testing.expect_value(t, wayu.native_jump_score({4, now - c.age}, now), c.score)
	}

	testing.expect(t, wayu.native_jump_path_matches("/Dev/Project-Wayu", {"dev", "wayu"}))
	testing.expect(t, !wayu.native_jump_path_matches("/Dev/Wayu/tests", {"dev", "wayu"}))
	testing.expect(t, !wayu.native_jump_path_matches("/dev/wayu", {"wayu", "dev"}))
}

@(test)
test_native_jump_aging :: proc(t: ^testing.T) {
	visits := make(map[string]wayu.Native_Dir_Visit)
	defer delete(visits)

	visits["active"] = {9999, 42}
	visits["stale"] = {1, 21}
	wayu.native_jump_age(&visits)
	testing.expect_value(t, visits["active"].count, 9999)
	visits["other"] = {5000, 31}
	wayu.native_jump_age(&visits)
	testing.expect_value(t, visits["active"].count, 9999.0 * 0.6)
	testing.expect_value(t, visits["active"].last_visit, 42)
	testing.expect_value(t, visits["other"].count, 3000)
	testing.expect(t, "stale" not_in visits)
}
