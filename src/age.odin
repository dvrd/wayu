// age.odin - age key encodings and the X25519 recipient stanza (OKAMI-370).
//
//   bech32            BIP-173 (not bech32m): age encodes keys with it.
//   recipient         "age1…": bech32, HRP "age", the 32-byte X25519 public
//                     key. "age1pq1…" (HRP "age1pq", post-quantum) is
//                     reserved: recognized and refused with its own error.
//   identity          "AGE-SECRET-KEY-1…": bech32, HRP "AGE-SECRET-KEY-",
//                     upper case, the 32-byte X25519 scalar.
//   X25519 stanza     the age v1 X25519 recipient derivation
//                     (C2SP age spec): ephemeral share E = X25519(e, G);
//                     wrap key = HKDF-SHA256(salt = E || R, ikm = X25519(e, R),
//                     info "age-encryption.org/v1/X25519"); body =
//                     ChaCha20-Poly1305(wrap key, zero nonce, no AAD,
//                     payload). Unwrapping rejects an all-zero shared secret.
//                     age wraps a 16-byte file key; wayu a 32-byte data key
//                     (the body is 48 bytes), so the math is age's but the
//                     container is wayu's (secrets_recipients.odin).
//
// Only core:crypto. Secret scalars and wrap keys are wiped after use.

package wayu

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:strings"

AGE_RECIPIENT_HRP :: "age"
AGE_PQ_RECIPIENT_HRP :: "age1pq" // reserved: post-quantum (ML-KEM-768 + X25519)
AGE_IDENTITY_HRP :: "AGE-SECRET-KEY-"
AGE_X25519_INFO :: "age-encryption.org/v1/X25519"

AGE_KEY_SIZE :: 32 // X25519 scalar / point

// ---------------------------------------------------------------------------
// bech32 (BIP-173)
// ---------------------------------------------------------------------------

BECH32_CHARSET :: "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

// BIP-173's 90-character limit (bech32_decode's default `max_len`).
BECH32_MAX_LEN :: 90

@(private = "file")
bech32_polymod :: proc(values: []byte) -> u32 {
	GEN := [5]u32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk: u32 = 1
	for v in values {
		top := chk >> 25
		chk = (chk & 0x1ffffff) << 5 ~ u32(v)
		for i in 0 ..< 5 {
			if (top >> uint(i)) & 1 == 1 {
				chk ~= GEN[i]
			}
		}
	}
	return chk
}

// hrp (lower case) expanded for the checksum, followed by `data`
// (temp-allocated).
@(private = "file")
bech32_checksum_input :: proc(hrp: string, data: []byte, extra := 0) -> []byte {
	out := make([dynamic]byte, 0, 2 * len(hrp) + 1 + len(data) + extra, context.temp_allocator)
	for i in 0 ..< len(hrp) {append(&out, hrp[i] >> 5)}
	append(&out, 0)
	for i in 0 ..< len(hrp) {append(&out, hrp[i] & 31)}
	append(&out, ..data)
	for _ in 0 ..< extra {append(&out, 0)}
	return out[:]
}

// Regroup bits (8 → 5 to encode, 5 → 8 to decode). ok = false for a value
// out of range, or (pad = false) leftover bits that are not zero padding.
// Temp-allocated. Identity bits pass through here and the procs below:
// every temporary copy is wiped (bech32_wipe) before it is dropped.
bech32_convert_bits :: proc(data: []byte, from, to: uint, pad: bool) -> (out: []byte, ok: bool) {
	acc: u32 = 0
	bits: uint = 0
	maxv: u32 = (1 << to) - 1
	max_acc: u32 = (1 << (from + to - 1)) - 1
	res := make([dynamic]byte, 0, len(data) * int(from) / int(to) + 1, context.temp_allocator)
	for v in data {
		if u32(v) >> from != 0 {
			bech32_wipe(res[:])
			return nil, false
		}
		acc = ((acc << from) | u32(v)) & max_acc
		bits += from
		for bits >= to {
			bits -= to
			append(&res, byte((acc >> bits) & maxv))
		}
	}
	if pad {
		if bits > 0 {
			append(&res, byte((acc << (to - bits)) & maxv))
		}
	} else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
		bech32_wipe(res[:])
		return nil, false
	}
	return res[:], true
}

@(private = "file")
bech32_wipe :: proc(b: []byte) {
	if len(b) > 0 {
		crypto.zero_explicit(raw_data(b), len(b))
	}
}

// bech32 string of `hrp` + 5-bit `data` (temp-allocated). `upper` writes it
// in upper case (age identities).
bech32_encode :: proc(hrp: string, data: []byte, upper := false) -> string {
	lhrp := strings.to_lower(hrp, context.temp_allocator)
	input := bech32_checksum_input(lhrp, data, 6)
	pm := bech32_polymod(input) ~ 1
	bech32_wipe(input)
	charset := BECH32_CHARSET
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, lhrp)
	strings.write_byte(&b, '1')
	for d in data {strings.write_byte(&b, charset[d])}
	for i in 0 ..< 6 {
		strings.write_byte(&b, charset[(pm >> uint(5 * (5 - i))) & 31])
	}
	s := strings.to_string(b)
	if !upper {
		return s
	}
	u := strings.to_upper(s, context.temp_allocator)
	bech32_wipe(b.buf[:])
	return u
}

// Decode a bech32 string: hrp (lower case) and the 5-bit data without the
// checksum (both temp-allocated). Rejects mixed case, characters outside
// 33..126, a missing or misplaced separator, characters outside the
// charset, a bad checksum, and (max_len > 0) strings longer than max_len.
bech32_decode :: proc(
	s: string,
	max_len := BECH32_MAX_LEN,
) -> (
	hrp: string,
	data: []byte,
	ok: bool,
) {
	if len(s) < 8 || (max_len > 0 && len(s) > max_len) {
		return
	}
	has_lower, has_upper := false, false
	for i in 0 ..< len(s) {
		c := s[i]
		if c < 33 || c > 126 {
			return
		}
		if c >= 'a' && c <= 'z' {
			has_lower = true
		}
		if c >= 'A' && c <= 'Z' {
			has_upper = true
		}
	}
	if has_lower && has_upper {
		return
	}
	ls := strings.to_lower(s, context.temp_allocator)
	pos := strings.last_index_byte(ls, '1')
	if pos < 1 || pos + 7 > len(ls) {
		bech32_wipe(transmute([]byte)ls)
		return
	}
	// The data part of the lower-case copy (hrp stays: it is returned).
	defer bech32_wipe(transmute([]byte)ls[pos:])
	vals := make([]byte, len(ls) - pos - 1, context.temp_allocator)
	for i in pos + 1 ..< len(ls) {
		idx := strings.index_byte(BECH32_CHARSET, ls[i])
		if idx < 0 {
			bech32_wipe(vals)
			return
		}
		vals[i - pos - 1] = byte(idx)
	}
	input := bech32_checksum_input(ls[:pos], vals)
	valid := bech32_polymod(input) == 1
	bech32_wipe(input)
	if !valid {
		bech32_wipe(vals)
		return
	}
	bech32_wipe(vals[len(vals) - 6:]) // the checksum symbols
	return ls[:pos], vals[:len(vals) - 6], true
}

// ---------------------------------------------------------------------------
// age keys
// ---------------------------------------------------------------------------

// "age1…" for an X25519 public key (temp-allocated).
age_recipient_encode :: proc(pub: [AGE_KEY_SIZE]byte) -> string {
	p := pub
	five, _ := bech32_convert_bits(p[:], 8, 5, true)
	return bech32_encode(AGE_RECIPIENT_HRP, five)
}

// Parse an "age1…" recipient. err (temp-allocated) explains a rejection;
// a post-quantum "age1pq1…" recipient gets its own message.
age_recipient_decode :: proc(s: string) -> (pub: [AGE_KEY_SIZE]byte, err: string) {
	if strings.has_prefix(strings.to_lower(s, context.temp_allocator), "age1pq1") {
		return pub,
			"post-quantum age recipients (age1pq1…) are reserved but not supported yet: use the machine's 'wayu secrets identity' (age1…)"
	}
	hrp, five, ok := bech32_decode(s)
	if !ok {
		return pub,
			"not a valid age recipient (bech32 \"age1…\"): copy the exact output of 'wayu secrets identity'"
	}
	if hrp == AGE_PQ_RECIPIENT_HRP {
		return pub,
			"post-quantum age recipients (age1pq1…) are reserved but not supported yet: use the machine's 'wayu secrets identity' (age1…)"
	}
	if hrp != AGE_RECIPIENT_HRP {
		return pub, "not an age recipient (expected \"age1…\")"
	}
	if s != strings.to_lower(s, context.temp_allocator) {
		return pub, "an age recipient is written in lower case"
	}
	raw, cok := bech32_convert_bits(five, 5, 8, false)
	if !cok || len(raw) != AGE_KEY_SIZE {
		return pub, "not an X25519 age recipient (wrong key length)"
	}
	copy(pub[:], raw)
	return pub, ""
}

// "AGE-SECRET-KEY-1…" for an X25519 scalar (temp-allocated; the caller
// wipes it).
age_identity_encode :: proc(secret: [AGE_KEY_SIZE]byte) -> string {
	k := secret
	defer crypto.zero_explicit(&k, size_of(k))
	five, _ := bech32_convert_bits(k[:], 8, 5, true)
	defer crypto.zero_explicit(raw_data(five), len(five))
	return bech32_encode(AGE_IDENTITY_HRP, five, upper = true)
}

// Parse "AGE-SECRET-KEY-1…" (upper case, as age writes it).
age_identity_decode :: proc(s: string) -> (secret: [AGE_KEY_SIZE]byte, ok: bool) {
	upper := strings.to_upper(s, context.temp_allocator)
	same := s == upper
	bech32_wipe(transmute([]byte)upper)
	if !same {
		return
	}
	hrp, five, dok := bech32_decode(s)
	defer if dok {
		crypto.zero_explicit(raw_data(five), len(five))
	}
	if !dok || hrp != strings.to_lower(AGE_IDENTITY_HRP, context.temp_allocator) {
		return
	}
	raw, cok := bech32_convert_bits(five, 5, 8, false)
	if !cok || len(raw) != AGE_KEY_SIZE {
		bech32_wipe(raw)
		return
	}
	copy(secret[:], raw)
	bech32_wipe(raw)
	return secret, true
}

// The public key (recipient) of an X25519 scalar.
age_identity_public :: proc(secret: [AGE_KEY_SIZE]byte) -> (pub: [AGE_KEY_SIZE]byte) {
	k := secret
	defer crypto.zero_explicit(&k, size_of(k))
	x25519.scalarmult_basepoint(pub[:], k[:])
	return
}

// ---------------------------------------------------------------------------
// X25519 stanza
// ---------------------------------------------------------------------------

// age's wrap key for share E and recipient R from the shared secret.
@(private = "file")
age_x25519_wrap_key :: proc(shared, share, recipient: []byte) -> (key: [32]byte) {
	salt: [2 * AGE_KEY_SIZE]byte
	copy(salt[:AGE_KEY_SIZE], share)
	copy(salt[AGE_KEY_SIZE:], recipient)
	hkdf.extract_and_expand(
		.SHA256,
		salt[:],
		shared,
		transmute([]byte)string(AGE_X25519_INFO),
		key[:],
	)
	return
}

// Wrap `payload` to `recipient` with ephemeral scalar `eph`. body is
// ciphertext || tag (len(payload) + 16, allocated with `allocator`).
// ok = false when the shared secret is all zero (a low-order recipient).
age_x25519_wrap :: proc(
	payload: []byte,
	recipient: [AGE_KEY_SIZE]byte,
	eph: [AGE_KEY_SIZE]byte,
	allocator := context.allocator,
) -> (
	share: [AGE_KEY_SIZE]byte,
	body: []byte,
	ok: bool,
) {
	e := eph
	r := recipient
	defer crypto.zero_explicit(&e, size_of(e))
	x25519.scalarmult_basepoint(share[:], e[:])
	shared: [AGE_KEY_SIZE]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	x25519.scalarmult(shared[:], e[:], r[:])
	zero: [AGE_KEY_SIZE]byte
	if crypto.compare_constant_time(shared[:], zero[:]) == 1 {
		return share, nil, false
	}
	wk := age_x25519_wrap_key(shared[:], share[:], r[:])
	defer crypto.zero_explicit(&wk, size_of(wk))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, wk[:])
	defer chacha20poly1305.reset(&ctx)
	body = make([]byte, len(payload) + chacha20poly1305.TAG_SIZE, allocator)
	nonce: [chacha20poly1305.IV_SIZE]byte
	chacha20poly1305.seal(&ctx, body[:len(payload)], body[len(payload):], nonce[:], nil, payload)
	return share, body, true
}

// Unwrap a stanza (share, body) with the identity scalar into `out`
// (len(body) - 16 bytes). ok = false for an all-zero shared secret, a
// body of the wrong length or a failed authentication.
age_x25519_unwrap :: proc(
	identity: [AGE_KEY_SIZE]byte,
	share: []byte,
	body: []byte,
	out: []byte,
) -> bool {
	if len(share) != AGE_KEY_SIZE ||
	   len(body) != len(out) + chacha20poly1305.TAG_SIZE ||
	   len(out) == 0 {
		return false
	}
	id := identity
	defer crypto.zero_explicit(&id, size_of(id))
	shared: [AGE_KEY_SIZE]byte
	defer crypto.zero_explicit(&shared, size_of(shared))
	x25519.scalarmult(shared[:], id[:], share)
	zero: [AGE_KEY_SIZE]byte
	if crypto.compare_constant_time(shared[:], zero[:]) == 1 {
		return false
	}
	pub := age_identity_public(id)
	wk := age_x25519_wrap_key(shared[:], share, pub[:])
	defer crypto.zero_explicit(&wk, size_of(wk))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, wk[:])
	defer chacha20poly1305.reset(&ctx)
	nonce: [chacha20poly1305.IV_SIZE]byte
	n := len(out)
	if !chacha20poly1305.open(&ctx, out, nonce[:], nil, body[:n], body[n:]) {
		crypto.zero_explicit(raw_data(out), len(out))
		return false
	}
	return true
}
