// config_toml_simple.odin - Simplified TOML parser using arenas
// This is a drop-in replacement for the complex pointer-based parser

package wayu

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"

// TomlDocSimple uses an arena for all allocations
toml_doc_parse_simple :: proc(content: string, arena: ^mem.Arena) -> (TomlDoc, bool) {
    doc: TomlDoc
    doc.values = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
    
    lines := strings.split(content, "\n")
    defer delete(lines)
    
    current_section := ""
    current_array_idx := -1  // -1 means not in an array of tables
    
    for line, line_num in lines {
        line_trimmed := strings.trim_space(line)
        
        // Skip empty lines and full-line comments
        if len(line_trimmed) == 0 || strings.has_prefix(line_trimmed, "#") {
            continue
        }
        
        // Remove inline comments (but not inside strings)
        in_string := false
        string_char: byte = 0
        comment_start := -1
        
        for i := 0; i < len(line_trimmed); i += 1 {
            c := line_trimmed[i]
            
            if !in_string && (c == '"' || c == '\'') {
                in_string = true
                string_char = c
            } else if in_string && c == string_char {
                in_string = false
            } else if !in_string && c == '#' {
                comment_start = i
                break
            }
        }
        
        if comment_start >= 0 {
            line_trimmed = strings.trim_space(line_trimmed[:comment_start])
        }
        
        // Check for array of tables [[section]] or [[section.sub.array]]
        if strings.has_prefix(line_trimmed, "[[") && strings.has_suffix(line_trimmed, "]]") {
            section_name := line_trimmed[2:len(line_trimmed)-2]
            current_section = strings.clone(section_name, allocator = mem.arena_allocator(arena))
            
            // Handle dotted array names like [[profile.work.aliases]]
            if strings.contains(section_name, ".") {
                parts := strings.split(section_name, ".")
                defer delete(parts)
                
                current_map := &doc.values
                for i := 0; i < len(parts) - 1; i += 1 {
                    part := parts[i]
                    
                    if existing, ok := current_map[part]; ok {
                        if existing.type != .TABLE {
                            existing.type = .TABLE
                            existing.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = mem.arena_allocator(arena))
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }
                
                array_name := parts[len(parts) - 1]
                
                arr_val, ok := current_map[array_name]
                if !ok {
                    arr_val = new(TomlValue, allocator = mem.arena_allocator(arena))
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                    current_map[array_name] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                }
                
                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            } else {
                arr_val, ok := doc.values[current_section]
                if !ok {
                    arr_val = new(TomlValue, allocator = mem.arena_allocator(arena))
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                    doc.values[current_section] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                }
                
                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            }
            continue
        }
        
        // Check for regular table [section] or [section.subsection]
        if strings.has_prefix(line_trimmed, "[") && strings.has_suffix(line_trimmed, "]") && !strings.has_prefix(line_trimmed, "[[") {
            section_name := line_trimmed[1:len(line_trimmed)-1]
            current_section = strings.clone(section_name, allocator = mem.arena_allocator(arena))
            current_array_idx = -1
            
            if strings.contains(section_name, ".") {
                parts := strings.split(section_name, ".")
                defer delete(parts)
                
                current_map := &doc.values
                for i := 0; i < len(parts); i += 1 {
                    part := parts[i]
                    
                    if existing, ok := current_map[part]; ok {
                        if existing.type != .TABLE {
                            existing.type = .TABLE
                            existing.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = mem.arena_allocator(arena))
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }
            } else {
                if _, ok := doc.values[current_section]; !ok {
                    table_val := new(TomlValue, allocator = mem.arena_allocator(arena))
                    table_val.type = .TABLE
                    table_val.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                    doc.values[current_section] = table_val
                }
            }
            continue
        }
        
        // Parse key = value
        if strings.contains(line_trimmed, "=") {
            eq_idx := strings.index(line_trimmed, "=")
            if eq_idx > 0 {
                key := strings.trim_space(line_trimmed[:eq_idx])
                value_str := strings.trim_space(line_trimmed[eq_idx+1:])
                
                val := parse_toml_value_simple(value_str, arena)
                
                if current_array_idx >= 0 && len(current_section) > 0 {
                    if strings.contains(current_section, ".") {
                        parts := strings.split(current_section, ".")
                        defer delete(parts)
                        
                        current_map := &doc.values
                        for i := 0; i < len(parts) - 1; i += 1 {
                            part := parts[i]
                            if existing, ok := current_map[part]; ok && existing.type == .TABLE {
                                current_map = &existing.table_val
                            } else {
                                break
                            }
                        }
                        
                        array_name := parts[len(parts) - 1]
                        if arr_val, ok := current_map[array_name]; ok && arr_val.type == .ARRAY {
                            if current_array_idx < len(arr_val.arr_val) {
                                table_ptr := &arr_val.arr_val[current_array_idx]
                                table_ptr.table_val[key] = val
                            }
                        }
                    } else {
                        arr_val := doc.values[current_section]
                        if arr_val != nil && arr_val.type == .ARRAY && current_array_idx < len(arr_val.arr_val) {
                            table_ptr := &arr_val.arr_val[current_array_idx]
                            table_ptr.table_val[key] = val
                        }
                    }
                } else if len(current_section) > 0 {
                    if strings.contains(current_section, ".") {
                        parts := strings.split(current_section, ".")
                        defer delete(parts)
                        
                        current_map := &doc.values
                        for part in parts {
                            if existing, ok := current_map[part]; ok && existing.type == .TABLE {
                                current_map = &existing.table_val
                            } else {
                                break
                            }
                        }
                        current_map[key] = val
                    } else {
                        table_val := doc.values[current_section]
                        if table_val != nil && table_val.type == .TABLE {
                            table_val.table_val[key] = val
                        }
                    }
                } else {
                    doc.values[key] = val
                }
            }
        }
    }
    
    return doc, true
}

parse_toml_value_simple :: proc(value_str: string, arena: ^mem.Arena) -> ^TomlValue {
    val := new(TomlValue, allocator = mem.arena_allocator(arena))
    
    s := strings.trim_space(value_str)
    
    if (strings.has_prefix(s, "\"") && strings.has_suffix(s, "\"")) ||
       (strings.has_prefix(s, "'") && strings.has_suffix(s, "'")) {
        val.type = .STRING
        if len(s) >= 2 {
            val.str_val = strings.clone(s[1:len(s)-1], allocator = mem.arena_allocator(arena))
        } else {
            val.str_val = ""
        }
        return val
    }
    
    if s == "true" {
        val.type = .BOOLEAN
        val.bool_val = true
        return val
    }
    if s == "false" {
        val.type = .BOOLEAN
        val.bool_val = false
        return val
    }
    
    if n, ok := strconv.parse_int(s); ok {
        val.type = .INTEGER
        val.int_val = n
        return val
    }
    
    if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") {
        val.type = .ARRAY
        val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            // Use bracket/quote-aware splitting so nested arrays, inline
            // tables and strings containing commas survive intact.
            elements := split_toml_top_level(inner, arena)
            defer delete(elements)
            for elem in elements {
                if len(elem) > 0 {
                    parsed_elem := parse_toml_value_simple(elem, arena)
                    append(&val.arr_val, parsed_elem^)
                }
            }
        }
        return val
    }

    // Inline table: { key = value, key2 = value2, ... }
    // Standard TOML inline-table syntax. Nested arrays/tables and quoted
    // strings (which may contain commas) are handled by split_toml_top_level.
    if strings.has_prefix(s, "{") && strings.has_suffix(s, "}") {
        val.type = .TABLE
        val.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            pairs := split_toml_top_level(inner, arena)
            defer delete(pairs)
            for pair in pairs {
                if len(pair) == 0 { continue }
                eq_idx := strings.index(pair, "=")
                if eq_idx <= 0 { continue }
                key := strings.trim_space(pair[:eq_idx])
                value_str := strings.trim_space(pair[eq_idx+1:])
                if len(key) == 0 { continue }
                child := parse_toml_value_simple(value_str, arena)
                key_clone := strings.clone(key, allocator = mem.arena_allocator(arena))
                val.table_val[key_clone] = child
            }
        }
        return val
    }

    val.type = .STRING
    val.str_val = strings.clone(s, allocator = mem.arena_allocator(arena))
    return val
}

// Split a TOML value-list at top-level commas, ignoring commas that appear
// inside quoted strings, [arrays], or {inline tables}. The returned slice
// header is allocated with the default allocator so callers can release it
// with a plain `delete(parts)`. Substrings are zero-copy views into `s`
// (which lives in the arena), so no per-element cleanup is required.
split_toml_top_level :: proc(s: string, arena: ^mem.Arena) -> []string {
    parts := make([dynamic]string)
    depth_brk := 0   // [ ] depth
    depth_brc := 0   // { } depth
    in_string := false
    string_char: byte = 0
    start := 0

    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if in_string {
            // Quote closes the string only if it's not preceded by an odd
            // number of backslashes — that catches `\"` (escaped) and
            // `\\"` (literal backslash followed by closing quote) correctly.
            if c == string_char {
                bs := 0
                for j := i - 1; j >= 0 && s[j] == '\\'; j -= 1 { bs += 1 }
                if bs % 2 == 0 {
                    in_string = false
                }
            }
            continue
        }
        switch c {
        case '"', '\'':
            in_string = true
            string_char = c
        case '[':
            depth_brk += 1
        case ']':
            if depth_brk > 0 { depth_brk -= 1 }
        case '{':
            depth_brc += 1
        case '}':
            if depth_brc > 0 { depth_brc -= 1 }
        case ',':
            if depth_brk == 0 && depth_brc == 0 {
                segment := strings.trim_space(s[start:i])
                append(&parts, segment)
                start = i + 1
            }
        }
    }
    if start <= len(s) {
        tail := strings.trim_space(s[start:])
        if len(tail) > 0 {
            append(&parts, tail)
        }
    }
    return parts[:]
}

get_toml_value_simple :: proc(doc: ^TomlDoc, key: string) -> ^TomlValue {
    if strings.contains(key, ".") {
        parts := strings.split(key, ".")
        defer delete(parts)
        
        current_map := &doc.values
        for part in parts {
            if val, ok := current_map[part]; ok {
                if val.type == .TABLE {
                    current_map = &val.table_val
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return nil
    }
    
    if val, ok := doc.values[key]; ok {
        return val
    }
    return nil
}
