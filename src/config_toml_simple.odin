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
            elements := strings.split(inner, ",")
            defer delete(elements)
            for elem in elements {
                elem_trimmed := strings.trim_space(elem)
                if len(elem_trimmed) > 0 {
                    parsed_elem := parse_toml_value_simple(elem_trimmed, arena)
                    append(&val.arr_val, parsed_elem^)
                }
            }
        }
        return val
    }
    
    val.type = .STRING
    val.str_val = strings.clone(s, allocator = mem.arena_allocator(arena))
    return val
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
