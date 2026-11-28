package wayu

import "base:intrinsics"
import "core:strconv"
import "core:strings"

Native_Arithmetic :: struct {
	rest:    string,
	session: ^Native_Session,
	error:   string,
}

native_arithmetic_expr :: proc(p: ^Native_Arithmetic, precedence, depth: int) -> i64 {
	if depth >= SHELL_MAX_NESTING {
		p.error = "expression nested too deeply"
		return 0
	}

	p.rest = strings.trim_left(p.rest, " \t\r\n")
	if p.rest == "" {
		p.error = "expected an operand"
		return 0
	}

	value: i64
	first := p.rest[0]
	if first == '(' {
		p.rest = p.rest[1:]
		value = native_arithmetic_expr(p, 0, depth + 1)
		if p.error != "" {
			return 0
		}

		if !strings.has_prefix(p.rest, ")") {
			p.error = "expected a closing parenthesis"
			return 0
		}

		p.rest = p.rest[1:]
	} else if (first == '+' || first == '-') &&
	   !(len(p.rest) > 1 && p.rest[1] >= '0' && p.rest[1] <= '9') {
		p.rest = p.rest[1:]
		value = native_arithmetic_expr(p, 3, depth + 1)
		if first == '-' {
			if value == min(i64) {
				p.error = "integer overflow"
				return 0
			}

			value = -value
		}
	} else {
		token := p.rest
		n := 0
		if first == '+' || first == '-' {
			n += 1
		}

		if token[n] >= '0' && token[n] <= '9' {
			for n < len(token) && token[n] >= '0' && token[n] <= '9' {n += 1}
			p.rest = token[n:]
			token = token[:n]
		} else {
			if first == '$' {
				token = token[1:]
			}

			for n < len(token) && is_env_var_char(token[n]) {n += 1}
			if !is_shell_var_name(token[:n]) {
				p.error = "expected an integer or variable"
				return 0
			}

			p.rest = token[n:]
			token = native_value(p.session, token[:n])
			if token == "" {
				token = "0"
			}
		}

		ok: bool
		value, ok = strconv.parse_i64(token, 10)
		if !ok {
			p.error = "expected a signed 64-bit integer"
			return 0
		}
	}

	for p.error == "" {
		p.rest = strings.trim_left(p.rest, " \t\r\n")
		if p.rest == "" || p.rest[0] == ')' {
			break
		}

		op := p.rest[0]
		level := 1
		switch op {
		case '+', '-':
		case '*', '/', '%':
			level = 2
		case:
			p.error = "unexpected operator"
			return 0
		}

		if level < precedence {
			break
		}

		p.rest = p.rest[1:]
		right := native_arithmetic_expr(p, level + 1, depth + 1)
		if p.error != "" {
			return 0
		}

		overflow: bool
		switch op {
		case '+':
			value, overflow = intrinsics.overflow_add(value, right)
		case '-':
			value, overflow = intrinsics.overflow_sub(value, right)
		case '*':
			value, overflow = intrinsics.overflow_mul(value, right)
		case '/', '%':
			if right == 0 {
				p.error = "division by zero"
				return 0
			}

			if value == min(i64) && right == -1 {
				overflow = op == '/'
				value = 0
			} else if op == '/' {
				value /= right
			} else {
				value %= right
			}
		}

		if overflow {
			p.error = "integer overflow"
			return 0
		}
	}

	return value
}

native_arithmetic :: proc(s: ^Native_Session, expression: string) -> (i64, string) {
	p := Native_Arithmetic {
		rest    = expression,
		session = s,
	}
	value := native_arithmetic_expr(&p, 0, 0)
	if p.error == "" && p.rest != "" {
		return 0, "unexpected closing parenthesis"
	}

	return value, p.error
}
