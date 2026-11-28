package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_native_arithmetic :: proc(t: ^testing.T) {
	for example in ([]struct {
			expr:  string,
			value: i64,
		} {
			{"8-3-2", 3},
			{"(2+3)*-4", -20},
			{"-7/3", -2},
			{"-7%3", -1},
			{"-9223372036854775808", min(i64)},
			{"-(+2)*3", -6},
		}) {
		value, err := wayu.native_arithmetic(nil, example.expr)
		testing.expect_value(t, err, "")
		testing.expect_value(t, value, example.value)
	}

	for expr in ([]string {
			"",
			"9/0",
			"9%0",
			"1+",
			"(2",
			"2)",
			"9 2",
			"1=2",
			"9223372036854775807+1",
			"-9223372036854775808/-1",
		}) {
		_, err := wayu.native_arithmetic(nil, expr)
		testing.expect(t, err != "")
	}
}
