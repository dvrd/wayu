package wayu

import "core:fmt"
import "core:mem/virtual"

// Keep source offsets for function definitions. Their bodies outlive the
// command arena and are parsed with the aliases in effect when invoked.
Native_Parser :: struct {
	session:    ^Native_Session,
	source:     string,
	tokens:     []ShellToken,
	i, depth:   int,
	err:        string,
	incomplete: bool,
}

Native_Node_Kind :: enum {
	Simple,
	Function,
	If,
	While,
	Until,
	For_Words,
	For_Positional,
}

Native_Node :: struct {
	kind:                    Native_Node_Kind,
	condition, name, source: string,
	test, body, otherwise:   []Native_Node,
	words:                   []ShellToken,
	pipelines:               []Native_Pipeline,
}

native_parser :: proc(
	s: ^Native_Session,
	source: string,
	stmts: []ShellStatement,
) -> Native_Parser {
	tokens := make([dynamic]ShellToken, context.temp_allocator)
	for stmt in stmts {
		if stmt.error != "" {
			return {err = stmt.error}
		}

		if len(tokens) > 0 && !native_continues(tokens[:]) {
			last := tokens[len(tokens) - 1]
			if last.kind != .Op || (last.op != ";" && last.op != "&") {
				append(&tokens, ShellToken{kind = .Op, op = ";", start = last.end, end = last.end})
			}
		}

		append(&tokens, ..stmt.tokens[:])
	}

	return {session = s, source = source, tokens = tokens[:]}
}

native_keyword :: proc(p: ^Native_Parser, delta := 0) -> string {
	if p.i + delta >= len(p.tokens) {
		return ""
	}

	t := p.tokens[p.i + delta]
	if t.kind == .Op {
		return t.op
	}

	if p.source[t.start:t.end] != t.word.text {
		return ""
	}

	return t.word.text
}

native_expect :: proc(p: ^Native_Parser, key: string) -> bool {
	if p.err != "" {
		return false
	}

	if native_keyword(p) == key {
		p.i += 1
		return true
	}

	p.err = fmt.tprintf("expected %s", key)
	p.incomplete = p.i == len(p.tokens)
	return false
}

native_required_list :: proc(p: ^Native_Parser) -> []Native_Node {
	body := native_list(p)
	if p.err == "" && len(body) == 0 {
		p.err = "expected a command in shell block"
		p.incomplete = p.i == len(p.tokens)
	}

	return body
}

native_if_body :: proc(p: ^Native_Parser) -> Native_Node {
	node := Native_Node {
		kind = .If,
	}

	node.test = native_required_list(p)
	if !native_expect(p, "then") {
		return node
	}

	node.body = native_required_list(p)
	switch native_keyword(p) {
	case "elif":
		p.i += 1
		next := make([]Native_Node, 1, context.temp_allocator)
		if p.depth >= 128 {
			p.err = "shell blocks nested too deeply"
			return node
		}

		p.depth += 1
		next[0] = native_if_body(p)
		p.depth -= 1
		node.otherwise = next
		return node
	case "else":
		p.i += 1
		node.otherwise = native_required_list(p)
	}

	_ = native_expect(p, "fi")
	return node
}

native_list :: proc(p: ^Native_Parser) -> []Native_Node {
	nodes := make([dynamic]Native_Node, context.temp_allocator)
	p.depth += 1
	defer p.depth -= 1

	if p.depth > 128 {
		p.err = "shell blocks nested too deeply"
		return nil
	}

	condition := ""
	for p.i < len(p.tokens) && p.err == "" {
		key := native_keyword(p)
		if key == ";" && p.tokens[p.i].start == p.tokens[p.i].end {
			p.i += 1
			continue
		}

		n: Native_Node
		switch key {
		case "then", "elif", "else", "fi", "do", "done", "}":
			if condition == "&&" || condition == "||" {
				p.err = "expected a command after conditional operator"
			}

			return nodes[:]
		case "if":
			p.i += 1
			n = native_if_body(p)
		case "while", "until":
			n.kind = .While if key == "while" else .Until
			p.i += 1
			n.test = native_required_list(p)
			if !native_expect(p, "do") {
				break
			}

			n.body = native_required_list(p)
			_ = native_expect(p, "done")
		case "for":
			n.kind = .For_Words
			p.i += 1
			n.name = native_keyword(p)
			if !is_shell_var_name(n.name) {
				p.err = "expected a loop variable"
				p.incomplete = p.i == len(p.tokens)
				break
			}

			p.i += 1
			if native_keyword(p) == "in" {
				p.i += 1
				start := p.i
				for p.i < len(p.tokens) && p.tokens[p.i].kind == .Word {p.i += 1}

				n.words = p.tokens[start:p.i]
			} else {
				n.kind = .For_Positional
			}

			if !native_expect(p, ";") || !native_expect(p, "do") {
				break
			}

			n.body = native_required_list(p)
			_ = native_expect(p, "done")
		case:
			if is_shell_var_name(key) && native_keyword(p, 1) == "(" {
				n.kind = .Function
				n.name = key
				p.i += 2
				if !native_expect(p, ")") {
					break
				}

				if native_keyword(p) == ";" {
					p.i += 1
				}

				if !native_expect(p, "{") {
					break
				}

				start := p.tokens[p.i - 1].end
				_ = native_required_list(p)
				if !native_expect(p, "}") {
					break
				}

				n.source = p.source[start:p.tokens[p.i - 1].start]
			} else {
				start := p.i
				for p.i < len(p.tokens) {
					t := p.tokens[p.i]
					if t.kind == .Op &&
					   (t.op == ";" || t.op == "&&" || t.op == "||" || t.op == "&") {
						break
					}

					p.i += 1
				}

				if p.i == start {
					p.err = "expected a command"
					break
				}

				raw := p.tokens[start:p.i]
				stmt: ShellStatement
				stmt.tokens = make([dynamic]ShellToken, context.temp_allocator)
				if p.session != nil {
					active := make(map[string]bool, context.temp_allocator)
					head, target := true, false
					native_alias_tokens(p.session, raw, &stmt.tokens, &active, &head, &target)
				} else {
					append(&stmt.tokens, ..raw)
				}

				n.kind = .Simple
				n.pipelines, p.err = native_parse([]ShellStatement{stmt})
				if len(n.pipelines) > 0 && native_keyword(p) == "&" {
					if condition == "&&" || condition == "||" {
						p.err = "background conditional lists are unsupported"
					}

					n.pipelines[len(n.pipelines) - 1].background = true
				}
			}
		}

		if p.err != "" {
			break
		}

		n.condition = condition
		append(&nodes, n)
		if p.i == len(p.tokens) {
			break
		}

		condition = native_keyword(p)
		if condition != ";" && condition != "||" && condition != "&&" && condition != "&" {
			p.err = "expected a command separator"
			break
		}

		if condition == "&" && n.kind != .Simple {
			p.err = "background compound commands are unsupported"
			break
		}

		p.i += 1
		if (condition == "&&" || condition == "||") && p.i == len(p.tokens) {
			p.err = "expected a command"
			p.incomplete = true
		}
	}

	return nodes[:]
}

native_run_list :: proc(s: ^Native_Session, nodes: []Native_Node) {
	for n in nodes {
		if native_stop_list(s) {
			return
		}

		if n.condition == "&&" && s.status != 0 || n.condition == "||" && s.status == 0 {
			continue
		}

		switch n.kind {
		case .Function:
			native_store(&s.definitions, n.name, n.source)
			s.status = 0
		case .If:
			native_run_list(s, n.test)
			if native_stop_list(s) {
				return
			}

			if s.status == 0 {
				native_run_list(s, n.body)
			} else {
				s.status = 0
				native_run_list(s, n.otherwise)
			}
		case .While, .Until:
			s.loop_depth += 1
			defer s.loop_depth -= 1

			defer s.loop_action = .None

			arena: virtual.Arena
			if virtual.arena_init_growing(&arena) != nil {
				s.status = 1
				return
			}

			defer virtual.arena_destroy(&arena)

			context.temp_allocator = virtual.arena_allocator(&arena)
			status := 0
			for !s.exiting && !s.returning {
				virtual.arena_free_all(&arena)
				native_run_list(s, n.test)
				if s.loop_action == .Break {
					break
				}

				if s.loop_action == .Continue {
					s.loop_action = .None
					continue
				}

				if native_stop_list(s) {
					return
				}

				if (s.status == 0) != (n.kind == .While) {
					break
				}

				native_run_list(s, n.body)
				status = s.status
				if s.loop_action == .Break {
					break
				}

				s.loop_action = .None
			}

			s.status = status
		case .For_Words, .For_Positional:
			s.loop_depth += 1
			defer s.loop_depth -= 1

			defer s.loop_action = .None

			args := make([dynamic]string, context.temp_allocator)
			if n.kind == .For_Positional {
				append(&args, ..s.positional)
			} else {
				for t in n.words {
					if !native_arguments(t.word, s, &args) {
						s.status = 1
						return
					}
				}
			}

			s.status = 0
			for v in args {
				native_assign(s, n.name, v)
				native_run_list(s, n.body)
				if s.loop_action == .Break {
					break
				}

				s.loop_action = .None
				if native_stop_list(s) {
					return
				}
			}
		case .Simple:
			for p in n.pipelines {
				if native_stop_list(s) {
					return
				}

				if p.condition == "&&" && s.status != 0 || p.condition == "||" && s.status == 0 {
					continue
				}

				s.status = native_pipeline(s, p)
			}
		}
	}
}
