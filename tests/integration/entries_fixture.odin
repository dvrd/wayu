package integration

import "core:encoding/json"
import "core:fmt"
import "core:testing"

Named_Value :: struct {
	name, value: string,
}
Fixture_Path :: struct {
	key, dir: string,
}

Fixture_Store :: struct {
	version:      int,
	paths:        []Fixture_Path,
	aliases, env: []Named_Value,
}
entries_path :: proc(cli: CLI) -> string {
	return fmt.tprintf("%s/.local/share/wayu/entries.json", cli.home)
}
read_store :: proc(t: ^testing.T, cli: CLI) -> Fixture_Store {
	store: Fixture_Store
	bytes := read_fixture(t, entries_path(cli))
	if err := json.unmarshal(transmute([]byte)bytes, &store, allocator = context.temp_allocator);
	   err != nil {
		testing.fail_now(t, fmt.tprintf("decode entries.json: %v", err))
	}
	return store
}
set_store :: proc(
	t: ^testing.T,
	cli: CLI,
	aliases: []Named_Value = nil,
	env: []Named_Value = nil,
	paths: []Fixture_Path = nil,
) {
	bytes, err := json.marshal(
		Fixture_Store{version = 1, aliases = aliases, env = env, paths = paths},
		allocator = context.temp_allocator,
	)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("encode entries.json: %v", err))
	}
	write_fixture(t, entries_path(cli), string(bytes))
}
named_value :: proc(rows: []Named_Value, name: string) -> (value: string, count: int) {
	for row in rows {
		if row.name == name {
			value = row.value; count += 1
		}
	}
	return
}
