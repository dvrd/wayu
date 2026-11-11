// test_secrets_recipients.odin - Multi-machine secrets (OKAMI-370): bech32
// (BIP-173 vectors), age keys, the X25519 stanza (C2SP CCTV age vectors).
// All keys and values are fake / test vectors.

package test_wayu

import wayu "../../src"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:strings"
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
