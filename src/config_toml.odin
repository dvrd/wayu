// config_toml.odin - TOML configuration file support for wayu
//
// This module provides TOML parsing, validation, and serialization for wayu's
// configuration files. It supports profiles, nested structures, and all
// configuration types defined in interfaces.odin.

package wayu

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:unicode"

// ============================================================================
// TOML PARSER STATE
// ============================================================================

TomlParser :: struct {
    content:    string,
    position:   int,
    line:       int,
    column:     int,
    errors:     [dynamic]string,
}

TomlTokenType :: enum {
    EOF,
    NEWLINE,
    IDENTIFIER,      // key names, section names
    STRING,          // "quoted" or 'quoted' or bare
    NUMBER,
    BOOLEAN,
    EQUALS,          // =
    LBRACKET,        // [
    RBRACKET,        // ]
    LBRACE,          // {
    RBRACE,          // }
    COMMA,           // ,
    DOT,             // .
    COMMENT,         // # comment
}

TomlToken :: struct {
    type:  TomlTokenType,
    value: string,
    line:  int,
}

// ============================================================================
// TOML PARSER IMPLEMENTATION
// ============================================================================

make_toml_parser :: proc(content: string) -> TomlParser {
    return TomlParser{
        content = content,
        position = 0,
        line = 1,
        column = 1,
        errors = make([dynamic]string),
    }
}

destroy_toml_parser :: proc(p: ^TomlParser) {
    for err in p.errors {
        delete(err)
    }
    delete(p.errors)
}

// Peek at current character without consuming
parser_peek :: proc(p: ^TomlParser) -> rune {
    if p.position >= len(p.content) {
        return '\x00'
    }
    return rune(p.content[p.position])
}

// Consume and return current character
parser_advance :: proc(p: ^TomlParser) -> rune {
    if p.position >= len(p.content) {
        return '\x00'
    }
    ch := rune(p.content[p.position])
    p.position += 1
    p.column += 1
    if ch == '\n' {
        p.line += 1
        p.column = 1
    }
    return ch
}

// Skip whitespace (but not newlines)
skip_whitespace :: proc(p: ^TomlParser) {
    for {
        ch := parser_peek(p)
        if ch == ' ' || ch == '\t' || ch == '\r' {
            parser_advance(p)
        } else {
            break
        }
    }
}

// Skip comment to end of line
skip_comment :: proc(p: ^TomlParser) {
    for {
        ch := parser_peek(p)
        if ch == '\n' || ch == '\x00' {
            break
        }
        parser_advance(p)
    }
}

// Parse a string value (quoted or bare)
parse_string :: proc(p: ^TomlParser) -> string {
    ch := parser_peek(p)
    
    // Handle quoted strings
    if ch == '"' || ch == '\'' {
        quote := ch
        parser_advance(p) // consume opening quote
        
        start := p.position
        for {
            current := parser_peek(p)
            if current == quote {
                parser_advance(p) // consume closing quote
                return p.content[start : p.position-1]
            }
            if current == '\x00' || current == '\n' {
                // Unterminated string
                return p.content[start:p.position]
            }
            parser_advance(p)
        }
    }
    
    // Bare string (for keys and simple values)
    start := p.position
    for {
        current := parser_peek(p)
        // Stop at whitespace, special chars, or end
        if current == ' ' || current == '\t' || current == '\n' || current == '\r' ||
           current == '\x00' || current == '#' || current == '=' || 
           current == '[' || current == ']' || current == '{' || current == '}' ||
           current == ',' || current == '.' {
            break
        }
        parser_advance(p)
    }
    
    return p.content[start:p.position]
}

// Parse a number (integer only for now)
parse_number :: proc(p: ^TomlParser) -> (int, bool) {
    start := p.position
    
    // Optional minus sign
    if parser_peek(p) == '-' {
        parser_advance(p)
    }
    
    // Digits
    has_digits := false
    for unicode.is_digit(parser_peek(p)) {
        parser_advance(p)
        has_digits = true
    }
    
    if !has_digits {
        return 0, false
    }
    
    num_str := p.content[start:p.position]
    val, ok := strconv.parse_int(num_str)
    return val, ok
}

// Get next token
next_token :: proc(p: ^TomlParser) -> TomlToken {
    skip_whitespace(p)
    
    ch := parser_peek(p)
    line := p.line
    
    // EOF
    if ch == '\x00' {
        return TomlToken{.EOF, "", line}
    }
    
    // Newline
    if ch == '\n' {
        parser_advance(p)
        return TomlToken{.NEWLINE, "\n", line}
    }
    
    // Comment
    if ch == '#' {
        skip_comment(p)
        return next_token(p)
    }
    
    // Single character tokens
    switch ch {
    case '=':
        parser_advance(p)
        return TomlToken{.EQUALS, "=", line}
    case '[':
        parser_advance(p)
        return TomlToken{.LBRACKET, "[", line}
    case ']':
        parser_advance(p)
        return TomlToken{.RBRACKET, "]", line}
    case '{':
        parser_advance(p)
        return TomlToken{.LBRACE, "{", line}
    case '}':
        parser_advance(p)
        return TomlToken{.RBRACE, "}", line}
    case ',':
        parser_advance(p)
        return TomlToken{.COMMA, ",", line}
    case '.':
        parser_advance(p)
        return TomlToken{.DOT, ".", line}
    }
    
    // String/identifier
    if ch == '"' || ch == '\'' {
        val := parse_string(p)
        return TomlToken{.STRING, val, line}
    }
    
    // Boolean or number or bare string
    if unicode.is_alpha(ch) || ch == '_' {
        start := p.position
        for unicode.is_alpha(parser_peek(p)) || parser_peek(p) == '_' {
            parser_advance(p)
        }
        val := p.content[start:p.position]
        
        if val == "true" || val == "false" {
            return TomlToken{.BOOLEAN, val, line}
        }
        return TomlToken{.IDENTIFIER, val, line}
    }
    
    if unicode.is_digit(ch) || ch == '-' {
        num_str_start := p.position
        if ch == '-' {
            parser_advance(p)
        }
        for unicode.is_digit(parser_peek(p)) {
            parser_advance(p)
        }
        num_str := p.content[num_str_start:p.position]
        return TomlToken{.NUMBER, num_str, line}
    }
    
    // Unknown character - skip it
    parser_advance(p)
    return next_token(p)
}

// ============================================================================
// TOML VALUE TYPES
// ============================================================================

TomlValueType :: enum {
    STRING,
    INTEGER,
    BOOLEAN,
    ARRAY,
    TABLE,
}

TomlValue :: struct {
    type: TomlValueType,
    str_val: string,
    int_val: int,
    bool_val: bool,
    arr_val: [dynamic]TomlValue,
    table_val: map[string]^TomlValue,
}

make_toml_string :: proc(s: string) -> TomlValue {
    return TomlValue{
        type = .STRING,
        str_val = strings.clone(s),
    }
}

make_toml_int :: proc(i: int) -> TomlValue {
    return TomlValue{
        type = .INTEGER,
        int_val = i,
    }
}

make_toml_bool :: proc(b: bool) -> TomlValue {
    return TomlValue{
        type = .BOOLEAN,
        bool_val = b,
    }
}

make_toml_array :: proc() -> TomlValue {
    return TomlValue{
        type = .ARRAY,
        arr_val = make([dynamic]TomlValue),
    }
}

make_toml_table :: proc() -> TomlValue {
    return TomlValue{
        type = .TABLE,
        table_val = make(map[string]^TomlValue),
    }
}

destroy_toml_value :: proc(v: ^TomlValue) {
    switch v.type {
    case .STRING:
        delete(v.str_val)
    case .ARRAY:
        for &elem in v.arr_val {
            destroy_toml_value(&elem)
        }
        delete(v.arr_val)
    case .TABLE:
        for _, val in v.table_val {
            destroy_toml_value(val)
            free(val)
        }
        delete(v.table_val)
    case .INTEGER, .BOOLEAN:
        // Nothing to free
    }
}

// ============================================================================
// TOML DOCUMENT
// ============================================================================

TomlDoc :: struct {
    values: map[string]^TomlValue,
}

make_toml_doc :: proc() -> TomlDoc {
    return TomlDoc{
        values = make(map[string]^TomlValue),
    }
}

destroy_toml_doc :: proc(doc: ^TomlDoc) {
    for _, val in doc.values {
        destroy_toml_value(val)
        free(val)
    }
    delete(doc.values)
}

// Get value from doc by key path (e.g., "path.entries")
get_toml_value :: proc(doc: ^TomlDoc, key: string) -> ^TomlValue {
    parts := strings.split(key, ".")
    defer delete(parts)
    
    if len(parts) == 0 {
        return nil
    }
    
    // First level
    val, ok := doc.values[parts[0]]
    if !ok {
        return nil
    }
    
    // Nested levels
    for i := 1; i < len(parts); i += 1 {
        if val.type != .TABLE {
            return nil
        }
        val, ok = val.table_val[parts[i]]
        if !ok {
            return nil
        }
    }
    
    return val
}

// Set value in doc by key path
set_toml_value :: proc(doc: ^TomlDoc, key: string, value: ^TomlValue) {
    parts := strings.split(key, ".")
    defer delete(parts)
    
    if len(parts) == 0 {
        return
    }
    
    if len(parts) == 1 {
        // Top-level key
        if existing, ok := doc.values[key]; ok {
            destroy_toml_value(existing)
            free(existing)
        }
        doc.values[key] = value
        return
    }
    
    // Create nested tables as needed
    current_table := doc.values
    for i := 0; i < len(parts) - 1; i += 1 {
        part := parts[i]
        
        next_table: map[string]^TomlValue
        if existing, ok := current_table[part]; ok {
            if existing.type == .TABLE {
                next_table = existing.table_val
            } else {
                // Replace with table
                destroy_toml_value(existing)
                table_val := make_toml_table()
                existing^ = table_val
                next_table = existing.table_val
            }
        } else {
            new_table := new(TomlValue)
            new_table^ = make_toml_table()
            current_table[part] = new_table
            next_table = new_table.table_val
        }
        
        // Move to next level
        current_table = next_table
    }
    
    // Set final value
    last_key := parts[len(parts) - 1]
    if existing, ok := current_table[last_key]; ok {
        destroy_toml_value(existing)
        free(existing)
    }
    current_table[last_key] = value
}

// ============================================================================
// TOML PARSING
// ============================================================================

// Parse a TOML value (string, number, boolean, array, inline table)
parse_toml_value :: proc(p: ^TomlParser, tokens: ^[]TomlToken, idx: ^int) -> (^TomlValue, bool) {
    if idx^ >= len(tokens^) {
        return nil, false
    }
    
    tok := tokens^[idx^]
    
    #partial switch tok.type {
    case .STRING:
        idx^ += 1
        val := new(TomlValue)
        val^ = make_toml_string(tok.value)
        return val, true
        
    case .NUMBER:
        idx^ += 1
        int_val, ok := strconv.parse_int(tok.value)
        if !ok {
            return nil, false
        }
        val := new(TomlValue)
        val^ = make_toml_int(int_val)
        return val, true
        
    case .BOOLEAN:
        idx^ += 1
        val := new(TomlValue)
        val^ = make_toml_bool(tok.value == "true")
        return val, true
        
    case .LBRACKET:
        // Array
        idx^ += 1 // skip [
        arr_val := make_toml_array()
        
        // Empty array
        if idx^ < len(tokens^) && tokens^[idx^].type == .RBRACKET {
            idx^ += 1
            val := new(TomlValue)
            val^ = arr_val
            return val, true
        }
        
        // Parse array elements
        for idx^ < len(tokens^) {
            if tokens^[idx^].type == .NEWLINE {
                idx^ += 1
                continue
            }
            if tokens^[idx^].type == .RBRACKET {
                idx^ += 1
                break
            }
            
            elem, ok := parse_toml_value(p, tokens, idx)
            if !ok {
                destroy_toml_value(&arr_val)
                return nil, false
            }
            append(&arr_val.arr_val, elem^)
            free(elem)
            
            // Skip comma
            if idx^ < len(tokens^) && tokens^[idx^].type == .COMMA {
                idx^ += 1
            }
        }
        
        val := new(TomlValue)
        val^ = arr_val
        return val, true
        
    case .LBRACE:
        // Inline table (not fully implemented - treat as empty for now)
        idx^ += 1
        // Skip to closing brace
        brace_count := 1
        for idx^ < len(tokens^) && brace_count > 0 {
            if tokens^[idx^].type == .LBRACE {
                brace_count += 1
            } else if tokens^[idx^].type == .RBRACE {
                brace_count -= 1
            }
            idx^ += 1
        }
        val := new(TomlValue)
        val^ = make_toml_table()
        return val, true
        
    case:
        return nil, false
    }
}

// Main TOML parsing function
toml_parse_doc :: proc(content: string) -> (TomlDoc, bool) {
    p := make_toml_parser(content)
    defer destroy_toml_parser(&p)
    
    doc := make_toml_doc()
    
    // Tokenize all input
    tokens := make([dynamic]TomlToken)
    defer delete(tokens)
    
    for {
        tok := next_token(&p)
        append(&tokens, tok)
        if tok.type == .EOF {
            break
        }
    }
    
    // Parse
    idx := 0
    current_table := ""  // Empty = root
    array_table := false
    active_table_path := "" // Full path for key insertion (e.g., "aliases[0]")
    
    for idx < len(tokens) {
        tok := tokens[idx]
        
        #partial switch tok.type {
        case .EOF:
            return doc, true
            
        case .NEWLINE:
            idx += 1
            
        case .LBRACKET:
            // Table or array of tables header
            idx += 1
            array_table = false
            
            // Check for array of tables [[...]]
            if idx < len(tokens) && tokens[idx].type == .LBRACKET {
                array_table = true
                idx += 1
            }
            
            // Parse table name
            table_name_parts := make([dynamic]string)
            defer delete(table_name_parts)
            
            for idx < len(tokens) {
                if tokens[idx].type == .RBRACKET {
                    idx += 1
                    if array_table && idx < len(tokens) && tokens[idx].type == .RBRACKET {
                        idx += 1
                    }
                    break
                }
                if tokens[idx].type == .IDENTIFIER || tokens[idx].type == .STRING {
                    append(&table_name_parts, tokens[idx].value)
                    idx += 1
                } else if tokens[idx].type == .DOT {
                    idx += 1
                } else {
                    break
                }
            }
            
            current_table = strings.join(table_name_parts[:], ".")
            
            // Create the table or array of tables using set_toml_value
            if len(current_table) > 0 {
                parts := strings.split(current_table, ".")
                defer delete(parts)
                
                // Ensure parent tables exist
                parent_path := ""
                for i := 0; i < len(parts) - 1; i += 1 {
                    if i > 0 {
                        parent_path = fmt.tprintf("%s.%s", parent_path, parts[i])
                    } else {
                        parent_path = parts[i]
                    }
                    
                    // Check if parent exists
                    if existing := get_toml_value(&doc, parent_path); existing == nil {
                        // Create parent table
                        new_table := new(TomlValue)
                        new_table^ = make_toml_table()
                        set_toml_value(&doc, parent_path, new_table)
                    }
                }
                
                // Handle the last part
                last_part := parts[len(parts) - 1]
                full_path := current_table
                
                if array_table {
                    // Array of tables [[...]]
                    // Check if array exists
                    arr_val := get_toml_value(&doc, full_path)
                    if arr_val == nil {
                        // Create new array
                        new_array := new(TomlValue)
                        new_array^ = make_toml_array()
                        set_toml_value(&doc, full_path, new_array)
                        arr_val = new_array
                    } else if arr_val.type != .ARRAY {
                        // Convert to array
                        arr_val^ = make_toml_array()
                    }
                    
                    // Add new table to array
                    new_table := make_toml_table()
                    append(&arr_val.arr_val, new_table)
                    // Note: We need to re-get the array since append may have reallocated
                    arr_val = get_toml_value(&doc, full_path)
                    // Build active_table_path for key insertion
                    table_idx := len(arr_val.arr_val) - 1
                    active_table_path = fmt.tprintf("%s[%d]", full_path, table_idx)
                } else {
                    // Regular table [...]
                    if existing := get_toml_value(&doc, full_path); existing == nil {
                        new_table := new(TomlValue)
                        new_table^ = make_toml_table()
                        set_toml_value(&doc, full_path, new_table)
                    }
                    active_table_path = full_path
                }
            }
            
        case .IDENTIFIER:
            // Key = value pair
            key := tok.value
            idx += 1
            
            // Check for dotted keys
            key_parts := make([dynamic]string)
            defer delete(key_parts)
            append(&key_parts, key)
            
            for idx < len(tokens) && tokens[idx].type == .DOT {
                idx += 1 // skip dot
                if idx < len(tokens) && (tokens[idx].type == .IDENTIFIER || tokens[idx].type == .STRING) {
                    append(&key_parts, tokens[idx].value)
                    idx += 1
                }
            }
            
            full_key := strings.join(key_parts[:], ".")
            defer delete(full_key)
            
            // Expect =
            if idx >= len(tokens) || tokens[idx].type != .EQUALS {
                // Invalid syntax - skip this line
                for idx < len(tokens) && tokens[idx].type != .NEWLINE {
                    idx += 1
                }
                continue
            }
            idx += 1 // skip =
            
            // Parse value
            tokens_slice := tokens[:]
            val, ok := parse_toml_value(&p, &tokens_slice, &idx)
            if !ok {
                continue
            }
            
            // Set the value with active_table_path prefix
            if len(active_table_path) > 0 {
                final_key := fmt.tprintf("%s.%s", active_table_path, full_key)
                defer delete(final_key)
                set_toml_value(&doc, final_key, val)
            } else {
                set_toml_value(&doc, full_key, val)
            }
            
        case:
            idx += 1
        }
    }
    
    return doc, true
}

// ============================================================================
// TOML TO CONFIG CONVERSION
// ============================================================================

// Extract string array from TOML value
get_string_array :: proc(val: ^TomlValue) -> ([]string, bool) {
    if val == nil || val.type != .ARRAY {
        return nil, false
    }
    
    result := make([dynamic]string)
    for elem in val.arr_val {
        if elem.type == .STRING {
            append(&result, strings.clone(elem.str_val))
        }
    }
    
    return result[:], true
}

// Extract string from TOML value
get_string :: proc(val: ^TomlValue, default: string = "") -> string {
    if val == nil || val.type != .STRING {
        return strings.clone(default)
    }
    return strings.clone(val.str_val)
}

// Extract int from TOML value
get_int :: proc(val: ^TomlValue, default: int = 0) -> int {
    if val == nil || val.type != .INTEGER {
        return default
    }
    return val.int_val
}

// Extract bool from TOML value
get_bool :: proc(val: ^TomlValue, default: bool = false) -> bool {
    if val == nil {
        return default
    }
    if val.type == .BOOLEAN {
        return val.bool_val
    }
    if val.type == .STRING {
        return val.str_val == "true"
    }
    return default
}

// Convert TomlDoc to TomlConfig
doc_to_config :: proc(doc: ^TomlDoc) -> (TomlConfig, bool) {
    config: TomlConfig
    
    // Temp dynamic arrays for building slices
    aliases_dyn := make([dynamic]TomlAlias)
    constants_dyn := make([dynamic]TomlConstant)
    plugins_dyn := make([dynamic]TomlPlugin)
    
    // Basic fields
    version_val := get_toml_value(doc, "version")
    config.version = get_string(version_val, "1.0")
    
    shell_val := get_toml_value(doc, "shell")
    config.shell = get_string(shell_val, "zsh")
    
    wayu_version_val := get_toml_value(doc, "wayu_version")
    config.wayu_version = get_string(wayu_version_val, VERSION)
    
    // Path config
    path_entries_val := get_toml_value(doc, "path.entries")
    if path_entries_val != nil {
        entries, ok := get_string_array(path_entries_val)
        if ok {
            config.path.entries = entries
        }
    }
    
    path_dedup_val := get_toml_value(doc, "path.dedup")
    config.path.dedup = get_bool(path_dedup_val, true)
    
    path_clean_val := get_toml_value(doc, "path.clean")
    config.path.clean = get_bool(path_clean_val, false)
    
    // Parse aliases - support both formats:
    // New format: [aliases] section with key = "value" pairs
    // Old format: [[aliases]] array of tables
    aliases_val := get_toml_value(doc, "aliases")
    if aliases_val != nil {
        if aliases_val.type == .TABLE {
            // New format: simple table with key-value pairs
            for name, cmd_val in aliases_val.table_val {
                if cmd_val.type == .STRING {
                    alias: TomlAlias
                    alias.name = strings.clone(name)
                    alias.command = strings.clone(cmd_val.str_val)
                    append(&aliases_dyn, alias)
                }
            }
        } else if aliases_val.type == .ARRAY {
            // Old format: array of tables [[aliases]]
            for alias_table in aliases_val.arr_val {
                if alias_table.type != .TABLE {
                    continue
                }
                
                alias: TomlAlias
                if name_val, ok := alias_table.table_val["name"]; ok && name_val.type == .STRING {
                    alias.name = strings.clone(name_val.str_val)
                }
                if cmd_val, ok := alias_table.table_val["command"]; ok && cmd_val.type == .STRING {
                    alias.command = strings.clone(cmd_val.str_val)
                }
                if desc_val, ok := alias_table.table_val["description"]; ok && desc_val.type == .STRING {
                    alias.description = strings.clone(desc_val.str_val)
                }
                
                if len(alias.name) > 0 {
                    append(&aliases_dyn, alias)
                }
            }
        }
    }
    
    // Parse constants - support both formats:
    // New format: [constants] section with NAME = "value" pairs
    // Old format: [[constants]] array of tables
    constants_val := get_toml_value(doc, "constants")
    if constants_val != nil {
        if constants_val.type == .TABLE {
            // New format: simple table with key-value pairs
            for name, val_val in constants_val.table_val {
                if val_val.type == .STRING {
                    constant: TomlConstant
                    constant.name = strings.clone(name)
                    constant.value = strings.clone(val_val.str_val)
                    constant.export = true  // Default to exported
                    append(&constants_dyn, constant)
                } else if val_val.type == .TABLE {
                    // Inline table format: CONSTANT = { value = "...", secret = true }
                    constant: TomlConstant
                    constant.name = strings.clone(name)
                    if v, ok := val_val.table_val["value"]; ok && v.type == .STRING {
                        constant.value = strings.clone(v.str_val)
                    }
                    if e, ok := val_val.table_val["export"]; ok {
                        constant.export = get_bool(e, true)
                    } else {
                        constant.export = true
                    }
                    if s, ok := val_val.table_val["secret"]; ok {
                        constant.secret = get_bool(s, false)
                    }
                    if len(constant.value) > 0 {
                        append(&constants_dyn, constant)
                    }
                }
            }
        } else if constants_val.type == .ARRAY {
            // Old format: array of tables [[constants]]
            for const_table in constants_val.arr_val {
                if const_table.type != .TABLE {
                    continue
                }
                
                constant: TomlConstant
                if name_val, ok := const_table.table_val["name"]; ok && name_val.type == .STRING {
                    constant.name = strings.clone(name_val.str_val)
                }
                if val_val, ok := const_table.table_val["value"]; ok && val_val.type == .STRING {
                    constant.value = strings.clone(val_val.str_val)
                }
                if export_val, ok := const_table.table_val["export"]; ok {
                    constant.export = get_bool(export_val, true)
                } else {
                    constant.export = true
                }
                if secret_val, ok := const_table.table_val["secret"]; ok {
                    constant.secret = get_bool(secret_val, false)
                }
                if desc_val, ok := const_table.table_val["description"]; ok && desc_val.type == .STRING {
                    constant.description = strings.clone(desc_val.str_val)
                }
                
                if len(constant.name) > 0 {
                    append(&constants_dyn, constant)
                }
            }
        }
    }
    
    // Parse plugins
    plugins_val := get_toml_value(doc, "plugins")
    if plugins_val != nil && plugins_val.type == .ARRAY {
        for plugin_table in plugins_val.arr_val {
            if plugin_table.type != .TABLE {
                continue
            }
            
            plugin: TomlPlugin
            if name_val, ok := plugin_table.table_val["name"]; ok && name_val.type == .STRING {
                plugin.name = strings.clone(name_val.str_val)
            }
            if source_val, ok := plugin_table.table_val["source"]; ok && source_val.type == .STRING {
                plugin.source = strings.clone(source_val.str_val)
            }
            if version_val, ok := plugin_table.table_val["version"]; ok && version_val.type == .STRING {
                plugin.version = strings.clone(version_val.str_val)
            }
            if defer_val, ok := plugin_table.table_val["defer"]; ok {
                plugin.defer_load = get_bool(defer_val, false)
            }
            if priority_val, ok := plugin_table.table_val["priority"]; ok {
                plugin.priority = get_int(priority_val, 100)
            } else {
                plugin.priority = 100
            }
            if cond_val, ok := plugin_table.table_val["condition"]; ok && cond_val.type == .STRING {
                plugin.condition = strings.clone(cond_val.str_val)
            }
            if desc_val, ok := plugin_table.table_val["description"]; ok && desc_val.type == .STRING {
                plugin.description = strings.clone(desc_val.str_val)
            }
            
            // Parse use array
            if use_val, ok := plugin_table.table_val["use"]; ok && use_val.type == .ARRAY {
                use_files, _ := get_string_array(use_val)
                plugin.use = use_files
            }
            
            if len(plugin.name) > 0 {
                append(&plugins_dyn, plugin)
            }
        }
    }
    
    // Assign dynamic arrays to config slices
    config.aliases = aliases_dyn[:]
    config.constants = constants_dyn[:]
    config.plugins = plugins_dyn[:]
    
    // Parse profiles
    profiles_val := get_toml_value(doc, "profile")
    if profiles_val != nil && profiles_val.type == .TABLE {
        for profile_name, profile_table in profiles_val.table_val {
            if profile_table.type != .TABLE {
                continue
            }
            
            profile: ProfileConfig
            
            // Parse profile path overrides
            if path_val, ok := profile_table.table_val["path"]; ok && path_val.type == .TABLE {
                profile.path = new(TomlPathConfig)
                if entries_val, ok2 := path_val.table_val["entries"]; ok2 && entries_val.type == .ARRAY {
                    entries, _ := get_string_array(entries_val)
                    profile.path.entries = entries
                }
                if dedup_val, ok2 := path_val.table_val["dedup"]; ok2 {
                    profile.path.dedup = get_bool(dedup_val, true)
                }
                if clean_val, ok2 := path_val.table_val["clean"]; ok2 {
                    profile.path.clean = get_bool(clean_val, false)
                }
            }
            
            // Temp dynamic arrays for profile
            profile_aliases_dyn := make([dynamic]TomlAlias)
            profile_constants_dyn := make([dynamic]TomlConstant)
            profile_plugins_dyn := make([dynamic]TomlPlugin)
            
            // Parse profile aliases - support both formats
            if aliases_val, ok := profile_table.table_val["aliases"]; ok {
                if aliases_val.type == .TABLE {
                    // New format: simple table
                    for name, cmd_val in aliases_val.table_val {
                        if cmd_val.type == .STRING {
                            alias: TomlAlias
                            alias.name = strings.clone(name)
                            alias.command = strings.clone(cmd_val.str_val)
                            append(&profile_aliases_dyn, alias)
                        }
                    }
                } else if aliases_val.type == .ARRAY {
                    // Old format: array of tables
                    for alias_table in aliases_val.arr_val {
                        if alias_table.type != .TABLE {
                            continue
                        }
                        alias: TomlAlias
                        if name_val, ok2 := alias_table.table_val["name"]; ok2 && name_val.type == .STRING {
                            alias.name = strings.clone(name_val.str_val)
                        }
                        if cmd_val, ok2 := alias_table.table_val["command"]; ok2 && cmd_val.type == .STRING {
                            alias.command = strings.clone(cmd_val.str_val)
                        }
                        if len(alias.name) > 0 {
                            append(&profile_aliases_dyn, alias)
                        }
                    }
                }
            }
            
            // Parse profile constants - support both formats
            if constants_val, ok := profile_table.table_val["constants"]; ok {
                if constants_val.type == .TABLE {
                    // New format: simple table
                    for name, val_val in constants_val.table_val {
                        if val_val.type == .STRING {
                            constant: TomlConstant
                            constant.name = strings.clone(name)
                            constant.value = strings.clone(val_val.str_val)
                            constant.export = true
                            append(&profile_constants_dyn, constant)
                        }
                    }
                } else if constants_val.type == .ARRAY {
                    // Old format: array of tables
                    for const_table in constants_val.arr_val {
                        if const_table.type != .TABLE {
                            continue
                        }
                        constant: TomlConstant
                        if name_val, ok2 := const_table.table_val["name"]; ok2 && name_val.type == .STRING {
                            constant.name = strings.clone(name_val.str_val)
                        }
                        if val_val, ok2 := const_table.table_val["value"]; ok2 && val_val.type == .STRING {
                            constant.value = strings.clone(val_val.str_val)
                        }
                        if len(constant.name) > 0 {
                            append(&profile_constants_dyn, constant)
                        }
                    }
                }
            }
            
            // Parse profile plugins
            if plugins_val, ok := profile_table.table_val["plugins"]; ok && plugins_val.type == .ARRAY {
                for plugin_table in plugins_val.arr_val {
                    if plugin_table.type != .TABLE {
                        continue
                    }
                    plugin: TomlPlugin
                    if name_val, ok2 := plugin_table.table_val["name"]; ok2 && name_val.type == .STRING {
                        plugin.name = strings.clone(name_val.str_val)
                    }
                    if len(plugin.name) > 0 {
                        append(&profile_plugins_dyn, plugin)
                    }
                }
            }
            
            // Assign dynamic arrays to profile slices
            profile.aliases = profile_aliases_dyn[:]
            profile.constants = profile_constants_dyn[:]
            profile.plugins = profile_plugins_dyn[:]
            
            // Parse profile condition
            if cond_val, ok := profile_table.table_val["condition"]; ok && cond_val.type == .STRING {
                profile.condition = strings.clone(cond_val.str_val)
            }
            
            config.profiles[profile_name] = profile
        }
    }
    
    // Parse settings
    settings_val := get_toml_value(doc, "settings")
    if settings_val != nil && settings_val.type == .TABLE {
        if auto_backup_val, ok := settings_val.table_val["auto_backup"]; ok {
            config.settings.auto_backup = get_bool(auto_backup_val, true)
        }
        if fuzzy_val, ok := settings_val.table_val["fuzzy_fallback"]; ok {
            config.settings.fuzzy_fallback = get_bool(fuzzy_val, true)
        }
        if dry_run_val, ok := settings_val.table_val["dry_run_default"]; ok {
            config.settings.dry_run_default = get_bool(dry_run_val, false)
        }
        if accept_keys_val, ok := settings_val.table_val["autosuggestions_accept_keys"]; ok && accept_keys_val.type == .ARRAY {
            accept_keys, ok2 := get_string_array(accept_keys_val)
            if ok2 {
                config.settings.autosuggestions_accept_keys = accept_keys
            }
        }
    }
    if config.settings.autosuggestions_accept_keys == nil || len(config.settings.autosuggestions_accept_keys) == 0 {
        config.settings.autosuggestions_accept_keys = []string{
            strings.clone("^Y"),
            strings.clone("^[[121;5u"),
        }
    }
    
    return config, true
}

// ============================================================================
// PUBLIC API (from interfaces.odin)
// ============================================================================

// Parse TOML content into TomlConfig
toml_parse :: proc(content: string) -> (TomlConfig, bool) {
    // Use arena-based simple parser for reliability
    arena: mem.Arena
    arena_buffer := make([]byte, 1024*1024, context.allocator)
    defer delete(arena_buffer)
    mem.arena_init(&arena, arena_buffer)
    
    doc, ok := toml_doc_parse_simple(content, &arena)
    if !ok {
        return {}, false
    }
    // Note: arena is freed automatically via defer, no need for destroy_toml_doc
    
    return doc_to_config(&doc)
}

// Validate TOML configuration
toml_validate :: proc(config: TomlConfig) -> ValidationResult {
    // Check version
    if config.version != "1.0" && config.version != "" {
        return ValidationResult{
            valid = false,
            error_message = fmt.aprintf("Unsupported config version: %s", config.version),
        }
    }
    
    // Check shell
    if config.shell != "" {
        valid_shells := []string{"zsh", "bash", "fish"}
        found := false
        for s in valid_shells {
            if config.shell == s {
                found = true
                break
            }
        }
        if !found {
            return ValidationResult{
                valid = false,
                error_message = fmt.aprintf("Invalid shell: %s (must be zsh, bash, or fish)", config.shell),
            }
        }
    }
    
    // Validate aliases
    for alias in config.aliases {
        result := validate_alias(alias.name, alias.command)
        if !result.valid {
            return ValidationResult{
                valid = false,
                error_message = fmt.aprintf("Invalid alias '%s': %s", alias.name, result.error_message),
            }
        }
        if result.warning != "" {
            delete(result.warning)
        }
    }
    
    // Validate constants
    for constant in config.constants {
        result := validate_constant(constant.name, constant.value)
        if !result.valid {
            return ValidationResult{
                valid = false,
                error_message = fmt.aprintf("Invalid constant '%s': %s", constant.name, result.error_message),
            }
        }
        if result.warning != "" {
            delete(result.warning)
        }
    }
    
    // Validate path entries
    for entry in config.path.entries {
        result := validate_path(entry)
        if !result.valid {
            return ValidationResult{
                valid = false,
                error_message = fmt.aprintf("Invalid path entry '%s': %s", entry, result.error_message),
            }
        }
    }
    
    return ValidationResult{valid = true, error_message = ""}
}

// Serialize TomlConfig to TOML string
toml_to_string :: proc(config: TomlConfig) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    
    // Header
    fmt.sbprintln(&builder, "# wayu configuration file")
    fmt.sbprintln(&builder, "# Documentation: https://github.com/dvrd/wayu")
    fmt.sbprintln(&builder)
    
    // Basic settings
    fmt.sbprintfln(&builder, "version = \"%s\"", config.version != "" ? config.version : "1.0")
    fmt.sbprintfln(&builder, "shell = \"%s\"", config.shell != "" ? config.shell : "zsh")
    fmt.sbprintfln(&builder, "wayu_version = \"%s\"", VERSION)
    fmt.sbprintln(&builder)
    
    // Path section
    fmt.sbprintln(&builder, "[path]")
    fmt.sbprint(&builder, "entries = [")
    for entry, i in config.path.entries {
        if i > 0 {
            fmt.sbprint(&builder, ", ")
        }
        fmt.sbprintf(&builder, "\"%s\"", entry)
    }
    fmt.sbprintln(&builder, "]")
    fmt.sbprintfln(&builder, "dedup = %t", config.path.dedup)
    fmt.sbprintfln(&builder, "clean = %t", config.path.clean)
    fmt.sbprintln(&builder)
    
    // Aliases
    if len(config.aliases) > 0 {
        for alias in config.aliases {
            fmt.sbprintln(&builder, "[[aliases]]")
            fmt.sbprintfln(&builder, "name = \"%s\"", alias.name)
            fmt.sbprintfln(&builder, "command = \"%s\"", alias.command)
            if alias.description != "" {
                fmt.sbprintfln(&builder, "description = \"%s\"", alias.description)
            }
            fmt.sbprintln(&builder)
        }
    }
    
    // Constants
    if len(config.constants) > 0 {
        for constant in config.constants {
            fmt.sbprintln(&builder, "[[constants]]")
            fmt.sbprintfln(&builder, "name = \"%s\"", constant.name)
            fmt.sbprintfln(&builder, "value = \"%s\"", constant.value)
            fmt.sbprintfln(&builder, "export = %t", constant.export)
            fmt.sbprintfln(&builder, "secret = %t", constant.secret)
            if constant.description != "" {
                fmt.sbprintfln(&builder, "description = \"%s\"", constant.description)
            }
            fmt.sbprintln(&builder)
        }
    }
    
    // Plugins
    if len(config.plugins) > 0 {
        for plugin in config.plugins {
            fmt.sbprintln(&builder, "[[plugins]]")
            fmt.sbprintfln(&builder, "name = \"%s\"", plugin.name)
            fmt.sbprintfln(&builder, "source = \"%s\"", plugin.source)
            if plugin.version != "" {
                fmt.sbprintfln(&builder, "version = \"%s\"", plugin.version)
            }
            if plugin.defer_load {
                fmt.sbprintln(&builder, "defer = true")
            }
            if plugin.priority != 100 {
                fmt.sbprintfln(&builder, "priority = %d", plugin.priority)
            }
            if plugin.condition != "" {
                fmt.sbprintfln(&builder, "condition = \"%s\"", plugin.condition)
            }
            if plugin.description != "" {
                fmt.sbprintfln(&builder, "description = \"%s\"", plugin.description)
            }
            if len(plugin.use) > 0 {
                fmt.sbprint(&builder, "use = [")
                for u, i in plugin.use {
                    if i > 0 {
                        fmt.sbprint(&builder, ", ")
                    }
                    fmt.sbprintf(&builder, "\"%s\"", u)
                }
                fmt.sbprintln(&builder, "]")
            }
            fmt.sbprintln(&builder)
        }
    }
    
    // Settings
    fmt.sbprintln(&builder, "[settings]")
    fmt.sbprintfln(&builder, "auto_backup = %t", config.settings.auto_backup)
    fmt.sbprintfln(&builder, "fuzzy_fallback = %t", config.settings.fuzzy_fallback)
    fmt.sbprintfln(&builder, "dry_run_default = %t", config.settings.dry_run_default)
    if len(config.settings.autosuggestions_accept_keys) > 0 {
        fmt.sbprint(&builder, "autosuggestions_accept_keys = [")
        for key, i in config.settings.autosuggestions_accept_keys {
            if i > 0 {
                fmt.sbprint(&builder, ", ")
            }
            fmt.sbprintf(&builder, "\"%s\"", key)
        }
        fmt.sbprintln(&builder, "]")
    }
    fmt.sbprintln(&builder)
    
    // Profiles
    if len(config.profiles) > 0 {
        for profile_name, profile in config.profiles {
            fmt.sbprintfln(&builder, "[profile.%s]", profile_name)
            
            if profile.path != nil {
                fmt.sbprintln(&builder, "  [profile.%s.path]")
                fmt.sbprint(&builder, "    entries = [")
                for entry, i in profile.path.entries {
                    if i > 0 {
                        fmt.sbprint(&builder, ", ")
                    }
                    fmt.sbprintf(&builder, "\"%s\"", entry)
                }
                fmt.sbprintln(&builder, "]")
            }
            
            for alias in profile.aliases {
                fmt.sbprintfln(&builder, "  [[profile.%s.aliases]]", profile_name)
                fmt.sbprintfln(&builder, "    name = \"%s\"", alias.name)
                fmt.sbprintfln(&builder, "    command = \"%s\"", alias.command)
            }
            
            for constant in profile.constants {
                fmt.sbprintfln(&builder, "  [[profile.%s.constants]]", profile_name)
                fmt.sbprintfln(&builder, "    name = \"%s\"", constant.name)
                fmt.sbprintfln(&builder, "    value = \"%s\"", constant.value)
            }
            
            if profile.condition != "" {
                fmt.sbprintfln(&builder, "  condition = \"%s\"", profile.condition)
            }
            
            fmt.sbprintln(&builder)
        }
    }
    
    return strings.clone(strings.to_string(builder))
}

// Merge profile into base config
toml_merge_profiles :: proc(base: TomlConfig, profile_name: string) -> TomlConfig {
    profile, ok := base.profiles[profile_name]
    if !ok {
        // Profile not found, return base unchanged
        return base
    }
    
    // Clone base config
    merged := base
    
    // Override path settings if profile has them
    if profile.path != nil {
        merged.path = profile.path^
    }
    
    // Temp dynamic arrays for merged config
    merged_aliases_dyn := make([dynamic]TomlAlias)
    merged_constants_dyn := make([dynamic]TomlConstant)
    merged_plugins_dyn := make([dynamic]TomlPlugin)
    
    // Copy existing aliases
    for alias in merged.aliases {
        append(&merged_aliases_dyn, alias)
    }
    // Append profile aliases
    for alias in profile.aliases {
        append(&merged_aliases_dyn, alias)
    }
    
    // Copy existing constants
    for constant in merged.constants {
        append(&merged_constants_dyn, constant)
    }
    // Append profile constants
    for constant in profile.constants {
        append(&merged_constants_dyn, constant)
    }
    
    // Copy existing plugins
    for plugin in merged.plugins {
        append(&merged_plugins_dyn, plugin)
    }
    // Append profile plugins
    for plugin in profile.plugins {
        append(&merged_plugins_dyn, plugin)
    }
    
    // Assign dynamic arrays to merged
    merged.aliases = merged_aliases_dyn[:]
    merged.constants = merged_constants_dyn[:]
    merged.plugins = merged_plugins_dyn[:]
    
    return merged
}

// Get active profile based on condition (simplified - returns first matching)
toml_get_active_profile :: proc(config: TomlConfig) -> string {
    for name, profile in config.profiles {
        if profile.condition != "" {
            // Simple condition evaluation could be expanded
            // For now, just return first profile with a condition
            return name
        }
    }
    return ""
}

// ============================================================================
// FILE OPERATIONS
// ============================================================================

TOML_CONFIG_FILE :: "wayu.toml"

// Read TOML config from file
toml_read_file :: proc(path: string) -> (TomlConfig, bool) {
    content, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil {
        return {}, false
    }
    defer delete(content)
    
    return toml_parse(string(content))
}

// Write TOML config to file
toml_write_file :: proc(path: string, config: TomlConfig) -> bool {
    content := toml_to_string(config)
    defer delete(content)
    
    err := os.write_entire_file(path, transmute([]byte)content)
    return err == nil
}

// Get default config file path
toml_get_config_path :: proc() -> string {
    return fmt.aprintf("%s/%s", WAYU_CONFIG, TOML_CONFIG_FILE)
}

// Create default TOML config
toml_create_default :: proc() -> TomlConfig {
    accept_keys := make([]string, 2)
    accept_keys[0] = strings.clone("^Y")
    accept_keys[1] = strings.clone("^[[121;5u")

    config := TomlConfig{
        version = "1.0",
        shell = "zsh",
        wayu_version = VERSION,
        path = TomlPathConfig{
            entries = make([]string, 0),
            dedup = true,
            clean = false,
        },
        aliases = make([]TomlAlias, 0),
        constants = make([]TomlConstant, 0),
        plugins = make([]TomlPlugin, 0),
        profiles = make(map[string]ProfileConfig),
        settings = WayuSettings{
            auto_backup = true,
            fuzzy_fallback = true,
            dry_run_default = false,
            autosuggestions_accept_keys = accept_keys,
        },
    }
    return config
}

// ============================================================================
// COMMAND HANDLERS
// ============================================================================

// Handle `wayu init --toml`
handle_init_toml :: proc() -> bool {
    config_path := toml_get_config_path()
    defer delete(config_path)
    
    // Check if file already exists
    if os.exists(config_path) {
        fmt.printfln("TOML config already exists: %s", config_path)
        fmt.println("Use --force to overwrite")
        return false
    }
    
    // Create default config
    config := toml_create_default()
    defer {
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        delete(config.plugins)
        for key in config.settings.autosuggestions_accept_keys {
            delete(key)
        }
        delete(config.settings.autosuggestions_accept_keys)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
        }
        delete(config.profiles)
    }
    
    // Write file
    if !toml_write_file(config_path, config) {
        fmt.eprintfln("Error: Failed to write %s", config_path)
        return false
    }
    
    fmt.printfln("Created TOML config: %s", config_path)
    return true
}

// Handle `wayu validate`
handle_validate :: proc() -> bool {
    config_path := toml_get_config_path()
    defer delete(config_path)
    
    if !os.exists(config_path) {
        fmt.eprintfln("Error: No TOML config found at %s", config_path)
        fmt.println("Run 'wayu init --toml' to create one")
        return false
    }
    
    config, ok := toml_read_file(config_path)
    if !ok {
        fmt.eprintfln("Error: Failed to parse %s", config_path)
        return false
    }
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        for key in config.settings.autosuggestions_accept_keys {
            delete(key)
        }
        delete(config.settings.autosuggestions_accept_keys)
        for alias in config.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(config.aliases)
        for constant in config.constants {
            delete(constant.name)
            delete(constant.value)
            delete(constant.description)
        }
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    result := toml_validate(config)
    
    if !result.valid {
        fmt.eprintfln("Validation failed: %s", result.error_message)
        delete(result.error_message)
        return false
    }
    
    fmt.println("✓ TOML config is valid")
    return true
}

// Handle `wayu convert --to-toml`
handle_convert_to_toml :: proc() -> bool {
    // This would migrate existing shell configs to TOML
    // For now, create a new config and populate from existing
    config_path := toml_get_config_path()
    defer delete(config_path)
    
    if os.exists(config_path) {
        fmt.eprintfln("Error: TOML config already exists at %s", config_path)
        return false
    }
    
    config := toml_create_default()
    defer {
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        delete(config.plugins)
        for key in config.settings.autosuggestions_accept_keys {
            delete(key)
        }
        delete(config.settings.autosuggestions_accept_keys)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
        }
        delete(config.profiles)
    }
    
    // TODO: Read existing shell configs and populate
    // This is a placeholder for future implementation
    
    if !toml_write_file(config_path, config) {
        fmt.eprintfln("Error: Failed to write %s", config_path)
        return false
    }
    
    fmt.printfln("Created TOML config: %s", config_path)
    fmt.println("Note: Migration from existing configs not yet fully implemented")
    return true
}

// Handle 'wayu toml show' - display TOML content
handle_toml_show :: proc() {
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	content, err := os.read_entire_file_from_path(toml_file, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read TOML file: %s", toml_file)
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	fmt.print(string(content))
}

// Handle 'wayu toml keys' - display TOML keys
handle_toml_keys :: proc() {
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	// Parse TOML to check it's valid
	config, ok := toml_read_file(toml_file)
	if !ok {
		fmt.eprintfln("Failed to parse TOML file: %s", toml_file)
		os.exit(EXIT_DATAERR)
	}

	// Print all top-level keys in sorted order
	keys := []string{"shell", "path", "aliases", "constants", "plugins", "hooks"}
	for key in keys {
		fmt.println(key)
	}
}

// Main handler for TOML command (wayu toml <action>)
handle_toml_command :: proc(action: Action) {
	#partial switch action {
	case .CHECK:
		// Validate TOML config
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		if !handle_validate() {
			os.exit(EXIT_DATAERR)
		}
	case .LIST:
		// Show all TOML keys
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		handle_toml_keys()
	case .GET:
		// Show TOML content
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		handle_toml_show()
	case .UPDATE:
		// Convert/apply TOML config
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		if !handle_convert_to_toml() {
			os.exit(EXIT_CANTCREAT)
		}
	case .HELP, .UNKNOWN:
		print_toml_usage()
	case:
		print_toml_usage()
	}
}

// Print TOML command usage
print_toml_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu toml - TOML configuration management%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu toml                    Validate TOML config (default)")
	fmt.printfln("  wayu toml validate           Validate wayu.toml syntax")
	fmt.printfln("  wayu toml show               Display TOML content")
	fmt.printfln("  wayu toml keys               List TOML keys")
	fmt.printfln("  wayu toml convert            Convert existing configs to TOML")
	fmt.printfln("  wayu toml apply              Apply TOML config to shell")
	fmt.printfln("  wayu toml help               Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage wayu configuration through TOML files.")
	fmt.println("  TOML enables declarative, version-controlled configs.")
	fmt.println()
	fmt.printfln("%sFILE LOCATIONS:%s", get_primary(), RESET)
	fmt.printfln("  ~/.config/wayu/wayu.toml         Main config (check into git)")
	fmt.printfln("  ~/.config/wayu/wayu.local.toml   Local overrides (gitignored)")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Validate your TOML config")
	fmt.println("  wayu toml validate")
	fmt.println()
	fmt.println("  # Convert existing shell configs to TOML")
	fmt.println("  wayu toml convert")
	fmt.println()
	fmt.println("  # Apply TOML config to shell")
	fmt.println("  wayu toml apply")
	fmt.println()
	fmt.printfln("%sSee:%s ~/.config/wayu/wayu.toml for example configuration", get_muted(), RESET)
}
