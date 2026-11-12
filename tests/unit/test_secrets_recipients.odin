// test_secrets_recipients.odin - Multi-machine secrets (OKAMI-370): bech32
// (BIP-173 vectors), age keys, the X25519 stanza (C2SP CCTV age vectors),
// secrets.json v2 parse/format, data-key pinning (rotation proofs), and the
// argon2id recovery stanza. All keys and values are fake / test vectors.

package test_wayu

import wayu "../../src"
import "base:runtime"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// ---------------------------------------------------------------------------
// bech32
// ---------------------------------------------------------------------------

@(test)
test_bech32_bip173_valid :: proc(t: ^testing.T) {
	valid := []string {
		"A12UEL5L",
		"a12uel5l",
		"an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
		"abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
		"11qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqc8247j",
		"split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w",
		"?1ezyfcl",
	}
	for s in valid {
		hrp, data, ok := wayu.bech32_decode(s)
		if !testing.expectf(t, ok, "BIP-173 valid vector rejected: %q", s) {
			continue
		}
		// Re-encoding gives the same string (lower case).
		again := wayu.bech32_encode(hrp, data)
		testing.expectf(
			t,
			again == strings.to_lower(s, context.temp_allocator),
			"re-encode of %q gave %q",
			s,
			again,
		)
	}
}

@(test)
test_bech32_bip173_invalid :: proc(t: ^testing.T) {
	invalid := []string {
		"\x201nwldj5", // HRP character out of range
		"\x7f1axkwrx", // HRP character out of range
		"\x801eym55h", // HRP character out of range
		"an84characterslonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1569pvx", // too long
		"pzry9x0s0muk", // no separator
		"1pzry9x0s0muk", // empty HRP
		"x1b4n0q5v", // invalid data character
		"li1dgmt3", // too short checksum
		"de1lg7wt\xff", // invalid character in checksum
		"A1G7SGD8", // checksum calculated with upper-case HRP
		"10a06t8", // empty HRP
		"1qzzfhee", // empty HRP
		"a12UEL5L", // mixed case
	}
	for s in invalid {
		_, _, ok := wayu.bech32_decode(s)
		testing.expectf(t, !ok, "BIP-173 invalid vector accepted: %q", s)
	}
}

// ---------------------------------------------------------------------------
// age keys + X25519 stanza: C2SP CCTV age test vectors
// (github.com/C2SP/CCTV/tree/main/age/testdata: x25519, x25519_low_order,
// x25519_bad_tag). The file key is "YELLOW SUBMARINE".
// ---------------------------------------------------------------------------

@(private = "file")
CCTV_IDENTITY :: "AGE-SECRET-KEY-1EGTZVFFV20835NWYV6270LXYVK2VKNX2MMDKWYKLMGR48UAWX40Q2P2LM0"
@(private = "file")
CCTV_FILE_KEY :: "59454c4c4f57205355424d4152494e45"

@(private = "file")
raw_b64 :: proc(s: string) -> []byte {
	out, err := base64.decode(
		s,
		allocator = context.temp_allocator,
		options = {.Strict, .No_Padding},
	)
	if err != nil {
		return nil
	}
	return out
}

@(test)
test_age_x25519_cctv_vectors :: proc(t: ^testing.T) {
	id, ok := wayu.age_identity_decode(CCTV_IDENTITY)
	if !testing.expect(t, ok, "CCTV identity does not decode") {
		return
	}
	// The identity re-encodes to the same string.
	testing.expect_value(t, wayu.age_identity_encode(id), CCTV_IDENTITY)
	// The recipient round-trips through bech32.
	pub := wayu.age_identity_public(id)
	r := wayu.age_recipient_encode(pub)
	back, rerr := wayu.age_recipient_decode(r)
	testing.expectf(t, rerr == "" && back == pub, "recipient %q: %q", r, rerr)

	want, _ := hex.decode(transmute([]byte)string(CCTV_FILE_KEY), context.temp_allocator)
	out: [16]byte

	// x25519: success, the file key.
	share := raw_b64("TEiF0ypqr+bpvcqXNyCVJpL7OuwPdVwPL7KQEbFDOCc")
	body := raw_b64("hjabGXwSLQ9c3S6Lw2i+S2Tu2fiwQHHslbBN6B41FLE")
	testing.expect(t, wayu.age_x25519_unwrap(id, share, body, out[:]), "x25519 vector: unwrap")
	testing.expect(t, string(out[:]) == string(want), "x25519 vector: wrong file key")

	// x25519_bad_tag: the body's tag is wrong.
	bad := raw_b64("hjabGXwSLQ9c3S6Lw2i+S2Tu2fiwQHHslbBN6B41FE4")
	testing.expect(t, !wayu.age_x25519_unwrap(id, share, bad, out[:]), "x25519_bad_tag accepted")

	// x25519_low_order: the shared secret is all zero.
	low := raw_b64("X5yVvKNQjCSx0LFVnIPvWwREXMRYHI6G2CJO3dCfEdc")
	lbody := raw_b64("3E0NpFans/m0WLWF7+54ZBdNj3iqQqpraGDFiaRkvBA")
	testing.expect(t, !wayu.age_x25519_unwrap(id, low, lbody, out[:]), "low-order share accepted")

	// A body that is not len(out) + 16 bytes is refused.
	big: [32]byte
	testing.expect(
		t,
		!wayu.age_x25519_unwrap(id, share, body, big[:]),
		"wrong body length accepted",
	)
}

@(test)
test_age_x25519_wrap_round_trip :: proc(t: ^testing.T) {
	id: [32]byte
	for &b, i in id {b = byte(i * 7 + 1)}
	other: [32]byte
	for &b, i in other {b = byte(i * 3 + 5)}
	eph: [32]byte
	for &b, i in eph {b = byte(200 - i)}
	key: [32]byte
	for &b, i in key {b = byte(i)}

	share, body, ok := wayu.age_x25519_wrap(key[:], wayu.age_identity_public(id), eph)
	defer delete(body)
	testing.expect(t, ok && len(body) == 48, "wrap")
	got: [32]byte
	testing.expect(t, wayu.age_x25519_unwrap(id, share[:], body, got[:]), "unwrap")
	testing.expect(t, got == key, "round trip")
	// Wrong identity (recipient) fails.
	testing.expect(t, !wayu.age_x25519_unwrap(other, share[:], body, got[:]), "wrong recipient")
	// A low-order recipient (all-zero point) is refused when wrapping.
	zero: [32]byte
	_, zbody, zok := wayu.age_x25519_wrap(key[:], zero, eph)
	delete(zbody)
	testing.expect(t, !zok, "all-zero shared secret must be refused")
}

@(test)
test_age_recipient_decode_rejects :: proc(t: ^testing.T) {
	id: [32]byte
	for &b, i in id {b = byte(i + 9)}
	good := wayu.age_recipient_encode(wayu.age_identity_public(id))
	_, err := wayu.age_recipient_decode(good)
	testing.expect_value(t, err, "")
	bad := []string {
		"",
		"age1",
		strings.to_upper(good, context.temp_allocator), // age recipients are lower case
		good[:len(good) - 1], // bad checksum
		CCTV_IDENTITY, // an identity, not a recipient
		"npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqgwdjkr", // other HRP
	}
	for s in bad {
		_, e := wayu.age_recipient_decode(s)
		testing.expectf(t, len(e) > 0, "accepted %q", s)
	}
	// Post-quantum recipients are reserved: a specific error.
	_, pq := wayu.age_recipient_decode("age1pq1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq")
	testing.expectf(t, strings.contains(pq, "post-quantum"), "age1pq: %q", pq)
}

// ---------------------------------------------------------------------------
// secrets.json version 2
// ---------------------------------------------------------------------------

@(private = "file")
fill_key :: proc(fill: byte) -> (k: [32]byte) {
	for &b, i in k {b = fill + byte(i)}
	return
}

@(private = "file")
recipient_of :: proc(id: [32]byte) -> string {
	return wayu.age_recipient_encode(wayu.age_identity_public(id))
}

// A version 2 store: data key `key`, recipient "laptop" (identity `id`),
// optionally "desk" (identity `other`), and two values.
@(private = "file")
make_v2_store :: proc(key, id: [32]byte, other: Maybe([32]byte) = nil) -> (s: wayu.Secrets_Store) {
	append(
		&s.entries,
		wayu.Secret_Entry {
			name = strings.clone("FAKE_A"),
			blob = wayu.secrets_seal(key, "FAKE_A", "fake-a"),
		},
	)
	append(
		&s.entries,
		wayu.Secret_Entry {
			name = strings.clone("FAKE_R"),
			blob = wayu.secrets_seal(key, "FAKE_R", "fake-r", run_only = true),
			run_only = true,
		},
	)
	wayu.secrets_store_upgrade(&s, key, "laptop", recipient_of(id))
	if o, ok := other.?; ok {
		wayu.secrets_recipient_put(&s, key, "desk", recipient_of(o))
	}
	return
}

@(test)
test_secrets_v2_format_parse_round_trip :: proc(t: ^testing.T) {
	key := fill_key(1)
	s := make_v2_store(key, fill_key(50), fill_key(90))
	defer wayu.secrets_store_destroy(&s)
	k1 := fill_key(7)
	ok, _ := wayu.secrets_store_reencrypt(&s, key, k1)
	testing.expect(t, ok, "reencrypt")
	ok, _ = wayu.secrets_store_rewrap_rotate(&s, key, k1)
	testing.expect(t, ok, "rewrap")
	rec, rok := wayu.secrets_recovery_make(k1, "fake passphrase 1234", {64, 1, 1})
	testing.expect(t, rok, "recovery")
	s.recovery = rec

	text := wayu.secrets_store_format(&s)
	defer delete(text)
	back, err := wayu.secrets_store_parse(text)
	defer wayu.secrets_store_destroy(&back)
	if !testing.expectf(t, err == "", "parse: %q\n%s", err, text) {
		return
	}
	testing.expect_value(t, back.version, wayu.SECRETS_VERSION_MULTI)
	testing.expect_value(t, back.key_id, wayu.secrets_key_id(k1))
	testing.expect_value(t, len(back.recipients), 2)
	testing.expect_value(t, len(back.rotations), 1)
	testing.expect_value(t, back.recovery.recipient, s.recovery.recipient)
	testing.expect_value(t, len(back.entries), 2)
	again := wayu.secrets_store_format(&back)
	defer delete(again)
	testing.expect_value(t, again, text)
	// The run-only mark and the value lines survive.
	testing.expect(t, strings.contains(text, `"run_only": ["FAKE_R"]`), text)
	// Every stanza is the one the key gives (nothing injected).
	testing.expect_value(t, wayu.secrets_recipients_check(&back, k1), "")
	v, vok := wayu.secrets_open(k1, "FAKE_R", back.entries[1].blob, run_only = true)
	testing.expect(t, vok && v == "fake-r", "value opens after the round trip")
	wayu.secrets_wipe(v)
}

// A valid v2 text with one field replaced: `old` → `new`.
@(private = "file")
v2_variant :: proc(t: ^testing.T, text, old, new: string) -> string {
	testing.expectf(t, strings.contains(text, old), "fixture lacks %q", old)
	out, _ := strings.replace(text, old, new, 1, context.temp_allocator)
	return out
}

@(test)
test_secrets_v2_parse_rejects :: proc(t: ^testing.T) {
	key := fill_key(3)
	s := make_v2_store(key, fill_key(60), fill_key(70))
	defer wayu.secrets_store_destroy(&s)
	k1 := fill_key(9)
	wayu.secrets_store_reencrypt(&s, key, k1)
	wayu.secrets_store_rewrap_rotate(&s, key, k1)
	text := wayu.secrets_store_format(&s)
	defer delete(text)
	r0 := s.recipients[0]
	r1 := s.recipients[1]
	pq := "age1pq1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
	Case :: struct {
		text: string,
		want: string, // substring of the error
	}
	cases := []Case {
		{v2_variant(t, text, `"cipher"`, `"extra": 1, "cipher"`), "unknown field"},
		{v2_variant(t, text, `{"name": "desk"`, `{"x": 1, "name": "desk"`), "unknown field"},
		{v2_variant(t, text, `"name": "laptop"`, `"name": "desk"`), "listed twice"},
		{v2_variant(t, text, r1.recipient, r0.recipient), "listed twice"},
		{v2_variant(t, text, s.key_id, "ABCDEF0123456789"), "key_id"},
		{v2_variant(t, text, s.key_id, "0123"), "key_id"},
		{v2_variant(t, text, `"run_only": ["FAKE_R"]`, `"run_only": ["FAKE_X"]`), "run_only"},
		{v2_variant(t, text, r0.recipient, pq), "post-quantum"},
		{v2_variant(t, text, r0.recipient, "age1notbech32"), "not a valid age recipient"},
		{v2_variant(t, text, r0.stanza, "AAAA BBBB"), "malformed stanza"},
		{v2_variant(t, text, `"name": "laptop"`, `"name": "lap top"`), "not valid"},
		{v2_variant(t, text, `"version": 2`, `"version": 3`), "newer wayu"},
		{v2_variant(t, text, `"version": 2`, `"version": 1`), "unknown field"},
		{v2_variant(t, text, s.rotations[0].proof, "AAAA"), "malformed proof"},
		// Duplicate JSON keys (the strict syntax check).
		{v2_variant(t, text, `"key_id"`, `"key_id": "x", "key_id"`), "appears twice"},
	}
	for c in cases {
		x, err := wayu.secrets_store_parse(c.text)
		wayu.secrets_store_destroy(&x)
		testing.expectf(t, strings.contains(err, c.want), "want %q, got %q", c.want, err)
	}
	// Empty recipients.
	start := strings.index(text, `"recipients": [`)
	end := strings.index(text, "  ],\n")
	empty := strings.concatenate(
		{text[:start], `"recipients": [`, "\n", text[end:]},
		context.temp_allocator,
	)
	x, err := wayu.secrets_store_parse(empty)
	wayu.secrets_store_destroy(&x)
	testing.expectf(t, strings.contains(err, "empty"), "empty recipients: %q", err)
	// More than 16 rotations.
	rot := strings.index(text, `    {"from"`)
	line := text[rot:strings.index(text[rot:], "\n") + rot]
	many := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 17 {
		strings.write_string(&many, line)
		strings.write_string(&many, ",\n" if i < 16 else "\n")
	}
	too_many, _ := strings.replace(
		text,
		strings.concatenate({line, "\n"}, context.temp_allocator),
		strings.to_string(many),
		1,
		context.temp_allocator,
	)
	y, yerr := wayu.secrets_store_parse(too_many)
	wayu.secrets_store_destroy(&y)
	testing.expectf(t, strings.contains(yerr, "at most 16"), "17 rotations: %q", yerr)
}

@(test)
test_secrets_rotation_chain :: proc(t: ^testing.T) {
	keys: [20][32]byte
	for &k, i in keys {k = fill_key(byte(10 * i + 1))}
	rots := make([dynamic]wayu.Secret_Rotation)
	defer {
		for r in rots {delete(r.from); delete(r.to); delete(r.proof)}
		delete(rots)
	}
	for i in 0 ..< 3 {append(&rots, wayu.secrets_rotation_make(keys[i], keys[i + 1]))}

	testing.expect(t, wayu.secrets_rotation_chain_verify(rots[:], keys[0], keys[3]), "valid chain")
	testing.expect(
		t,
		wayu.secrets_rotation_chain_verify(rots[:], keys[1], keys[3]),
		"chain from the middle",
	)
	testing.expect(t, wayu.secrets_rotation_chain_verify(rots[:], keys[2], keys[2]), "same key")
	testing.expect(t, !wayu.secrets_rotation_chain_verify(rots[:], keys[3], keys[0]), "backwards")
	testing.expect(
		t,
		!wayu.secrets_rotation_chain_verify(rots[:], keys[0], keys[4]),
		"unknown target",
	)
	// Cap: three steps with a cap of two.
	testing.expect(
		t,
		!wayu.secrets_rotation_chain_verify(rots[:], keys[0], keys[3], max_steps = 2),
		"longer than the cap",
	)
	// Gap: the middle link is missing.
	gap := []wayu.Secret_Rotation{rots[0], rots[2]}
	testing.expect(t, !wayu.secrets_rotation_chain_verify(gap, keys[0], keys[3]), "gap")
	// Forged: a link "from" key 1 signed by an attacker's key.
	forged := wayu.secrets_rotation_make(keys[9], keys[2])
	defer {delete(forged.from); delete(forged.to); delete(forged.proof)}
	delete(forged.from)
	forged.from = strings.clone(wayu.secrets_key_id(keys[1]))
	bad := []wayu.Secret_Rotation{rots[0], forged, rots[2]}
	testing.expect(t, !wayu.secrets_rotation_chain_verify(bad, keys[0], keys[3]), "forged link")
	// A proof does not reveal the new key: holding key 0 and the file, the
	// attacker key cannot be proven from key 0.
	attacker := wayu.secrets_rotation_make(keys[0], keys[9])
	defer {delete(attacker.from); delete(attacker.to); delete(attacker.proof)}
	testing.expect(
		t,
		wayu.secrets_rotation_chain_verify([]wayu.Secret_Rotation{attacker}, keys[0], keys[9]),
		"a holder of the old key can prove a new one (documented limit)",
	)
	testing.expect(
		t,
		!wayu.secrets_rotation_chain_verify([]wayu.Secret_Rotation{attacker}, keys[1], keys[9]),
		"but not from another key",
	)
	// 17 links: the default cap (16) refuses the full chain.
	long := make([dynamic]wayu.Secret_Rotation)
	defer {
		for r in long {delete(r.from); delete(r.to); delete(r.proof)}
		delete(long)
	}
	for i in 0 ..< 17 {append(&long, wayu.secrets_rotation_make(keys[i], keys[i + 1]))}
	testing.expect(t, !wayu.secrets_rotation_chain_verify(long[:], keys[0], keys[17]), "17 > cap")
	testing.expect(t, wayu.secrets_rotation_chain_verify(long[:], keys[1], keys[17]), "16 == cap")
}

@(test)
test_secrets_recipients_check_detects_injection :: proc(t: ^testing.T) {
	key := fill_key(5)
	s := make_v2_store(key, fill_key(40), fill_key(80))
	defer wayu.secrets_store_destroy(&s)
	testing.expect_value(t, wayu.secrets_recipients_check(&s, key), "")
	// An attacker without the key adds a recipient: it wraps the key it
	// does not have (any key), so the stanza is not the one `key` gives.
	wayu.secrets_recipient_put(&s, fill_key(99), "evil", recipient_of(fill_key(120)))
	testing.expect_value(t, wayu.secrets_recipients_check(&s, key), "evil")
	// Swapping two names breaks the binding too.
	t2 := make_v2_store(key, fill_key(40), fill_key(80))
	defer wayu.secrets_store_destroy(&t2)
	t2.recipients[0].name, t2.recipients[1].name = t2.recipients[1].name, t2.recipients[0].name
	testing.expect(t, wayu.secrets_recipients_check(&t2, key) != "", "swapped names")
	// The stanza opens with the right identity only.
	k, ok := wayu.secrets_stanza_open(fill_key(40), s.recipients[0].stanza)
	testing.expect(t, ok && k == key, "own stanza")
	_, ok = wayu.secrets_stanza_open(fill_key(41), s.recipients[0].stanza)
	testing.expect(t, !ok, "other identity")
}

@(test)
test_secrets_recovery_round_trip :: proc(t: ^testing.T) {
	key := fill_key(11)
	rec, ok := wayu.secrets_recovery_make(key, "fake recovery phrase", {64, 1, 1})
	defer wayu.secrets_recovery_destroy(&rec)
	if !testing.expect(t, ok, "make") {
		return
	}
	got, uok, wrong := wayu.secrets_recovery_unlock(&rec, "fake recovery phrase")
	testing.expect(t, uok && !wrong && got == key, "unlock with the passphrase")
	_, uok, wrong = wayu.secrets_recovery_unlock(&rec, "fake recovery phrasE")
	testing.expect(t, !uok && wrong, "wrong passphrase")
	// The KDF matches argon2id's RFC 9106 test vector shape (32-byte tag,
	// deterministic for the same inputs).
	salt := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	a, _ := wayu.secrets_recovery_kek("pw", salt, {64, 1, 1})
	b, _ := wayu.secrets_recovery_kek("pw", salt, {64, 1, 1})
	c, _ := wayu.secrets_recovery_kek("pw", salt, {64, 2, 1})
	testing.expect(t, a == b && a != c, "argon2id is deterministic and depends on t")
}

// v1 → v2 keeps every value line byte for byte (the 7.0 master key is the
// data key) and the result re-parses and verifies.
@(test)
test_secrets_v1_upgrade_keeps_value_lines :: proc(t: ^testing.T) {
	key := fill_key(21)
	v1: wayu.Secrets_Store
	defer wayu.secrets_store_destroy(&v1)
	for n in ([]string{"FAKE_B", "FAKE_A", "FAKE_C"}) {
		append(
			&v1.entries,
			wayu.Secret_Entry{name = strings.clone(n), blob = wayu.secrets_seal(key, n, "fake")},
		)
	}
	v1.entries[2].run_only = true
	delete(v1.entries[2].blob)
	v1.entries[2].blob = wayu.secrets_seal(key, "FAKE_C", "fake", run_only = true)
	old_text := wayu.secrets_store_format(&v1)
	defer delete(old_text)
	testing.expect(t, strings.contains(old_text, `"version": 1`), old_text)

	s, err := wayu.secrets_store_parse(old_text)
	defer wayu.secrets_store_destroy(&s)
	testing.expect_value(t, err, "")
	testing.expect(t, wayu.secrets_store_upgrade(&s, key, "laptop", recipient_of(fill_key(33))))
	new_text := wayu.secrets_store_format(&s)
	defer delete(new_text)
	rest := old_text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, `    "FAKE_`) || strings.has_prefix(line, `  "run_only"`) {
			testing.expectf(t, strings.contains(new_text, line), "value line changed: %q", line)
		}
	}
	back, perr := wayu.secrets_store_parse(new_text)
	defer wayu.secrets_store_destroy(&back)
	testing.expect_value(t, perr, "")
	testing.expect_value(t, back.key_id, wayu.secrets_key_id(key))
	k, ok := wayu.secrets_stanza_open(fill_key(33), back.recipients[0].stanza)
	testing.expect(t, ok && k == key, "this machine's stanza unwraps to the 7.0 key")
}

// ---------------------------------------------------------------------------
// Pinning (secrets_key_multi) with the file backend in a scratch config/data
// dir: never the keychain.
// ---------------------------------------------------------------------------

@(private = "file")
Pin_Sandbox :: struct {
	root, saved_config, saved_data: string,
}

@(private = "file")
pin_enter :: proc(name: string) -> (sb: Pin_Sandbox) {
	sb.root = test_tmp(name)
	os.remove_all(sb.root)
	config := strings.concatenate({sb.root, "/config"}, context.temp_allocator)
	data := strings.concatenate({sb.root, "/data"}, context.temp_allocator)
	os.make_directory_all(config)
	os.make_directory_all(data)
	sb.saved_config, sb.saved_data = wayu.wayu.config, wayu.wayu.data
	wayu.wayu.config = strings.clone(config, runtime.heap_allocator())
	wayu.wayu.data = strings.clone(data, runtime.heap_allocator())
	wayu.clear_toml_content_cache()
	wayu.TOML_CONTENT_CACHE.content = "[secrets]\nbackend = \"file\"\n"
	wayu.TOML_CONTENT_CACHE.loaded = true
	wayu.TOML_CONTENT_CACHE.owned = false
	return
}

@(private = "file")
pin_leave :: proc(sb: ^Pin_Sandbox) {
	wayu.clear_toml_content_cache()
	delete(wayu.wayu.config, runtime.heap_allocator())
	delete(wayu.wayu.data, runtime.heap_allocator())
	wayu.wayu.config, wayu.wayu.data = sb.saved_config, sb.saved_data
	os.remove_all(sb.root)
}

@(test)
test_secrets_pinning :: proc(t: ^testing.T) {
	sb := pin_enter("secrets_pinning")
	defer pin_leave(&sb)
	if !testing.expect(
		t,
		wayu.secrets_backend_active() == .FILE,
		"sandbox must use the file backend",
	) {
		return
	}
	id := fill_key(77)
	ok, msg := wayu.keystore_identity_save(.FILE, id)
	testing.expectf(t, ok, "identity save: %s", msg)
	// identity.key: 0600, age's layout, never replaced.
	st: posix.stat_t
	posix.stat(
		strings.clone_to_cstring(wayu.identity_key_file_path(), context.temp_allocator),
		&st,
	)
	testing.expect(t, st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) == {}, "identity.key is 0600")
	text, _ := os.read_entire_file_from_path(wayu.identity_key_file_path(), context.temp_allocator)
	testing.expect(t, strings.contains(string(text), "# public key: age1"), string(text))
	again, _ := wayu.keystore_identity_save(.FILE, fill_key(78))
	testing.expect(t, !again, "an identity is never overwritten")

	k0 := fill_key(1)
	s := make_v2_store(k0, id)
	defer wayu.secrets_store_destroy(&s)

	// TOFU: nothing cached → the stanza's key, cached.
	got, kok, kerr := wayu.secrets_key_multi(&s)
	testing.expectf(t, kok && got == k0, "TOFU: %s", kerr)
	cached, status, _ := wayu.keystore_load(.FILE)
	testing.expect(t, status == .OK && cached == k0, "TOFU caches the key")

	// Fast path: the cached key matches key_id.
	got, kok, _ = wayu.secrets_key_multi(&s)
	testing.expect(t, kok && got == k0, "cached key")

	// Rotation with a proof: adopted and cached.
	k1 := fill_key(2)
	wayu.secrets_store_reencrypt(&s, k0, k1)
	wayu.secrets_store_rewrap_rotate(&s, k0, k1)
	got, kok, kerr = wayu.secrets_key_multi(&s)
	testing.expectf(t, kok && got == k1, "adopt with proof: %s", kerr)
	cached, status, _ = wayu.keystore_load(.FILE)
	testing.expect(t, cached == k1, "the proven key is cached")

	// An attacker's key wrapped to this machine, no proof: refused with the
	// fix command, the cache untouched.
	evil := make_v2_store(fill_key(200), id)
	defer wayu.secrets_store_destroy(&evil)
	_, kok, kerr = wayu.secrets_key_multi(&evil)
	testing.expectf(
		t,
		!kok && strings.contains(kerr, "wayu secrets adopt --yes"),
		"refuse without proof: %q",
		kerr,
	)
	cached, status, _ = wayu.keystore_load(.FILE)
	testing.expect(t, cached == k1, "a refused key is not cached")

	// Not a recipient: names the fix.
	other := make_v2_store(k1, fill_key(140))
	defer wayu.secrets_store_destroy(&other)
	wayu.secrets_store_reencrypt(&other, k1, fill_key(3))
	wayu.secrets_store_rewrap_rotate(&other, k1, fill_key(3))
	_, kok, kerr = wayu.secrets_key_multi(&other)
	testing.expectf(
		t,
		!kok &&
		strings.contains(kerr, "not a recipient") &&
		strings.contains(kerr, "recipient add age1"),
		"not a recipient: %q",
		kerr,
	)
}
