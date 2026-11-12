// secrets_recipients.odin - Multi-machine secrets (OKAMI-370, experimental).
//
// secrets.json version 2 keeps the version 1 values (same AEAD, same AAD,
// same lines: the data key of a migrated store is the 7.0 master key) and
// adds a header:
//
//   "key_id"      hex(HKDF-SHA256(K, info "wayu/secrets/key-id")[:8]): the
//                 data key's fingerprint.
//   "recipients"  [{"name", "recipient": "age1…", "stanza": "<E> <body>"}]:
//                 K wrapped to each machine's age X25519 identity (age.odin;
//                 unpadded base64, body 48 bytes). The ephemeral scalar is
//                 HKDF(K, "wayu/secrets/stanza\0" name "\0" recipient), so a
//                 holder of K can recompute every stanza: one that does not
//                 match (an injected recipient, a renamed or swapped entry)
//                 is refused before K is ever wrapped to it again.
//   "recovery"    optional passphrase stanza (wayu-only): a random X25519
//                 identity sealed under argon2id(passphrase), K wrapped to it.
//   "rotations"   [{"from", "to", "proof"}], at most 16: proof =
//                 base64(VK_to || Ed25519 signature by SK_from over
//                 "wayu-secrets-rotate\0" from "\0" to "\0" VK_to), where
//                 (SK, VK) is derived from a data key (HKDF info
//                 "wayu/secrets/rotate-sign"). A chain proves a new key to a
//                 machine that holds an old one, without revealing the new
//                 key to holders of the old one (a removed machine).
//
// Pinning: every machine caches the data key it verified in the existing
// master-key item (keystore.odin). Shell start uses it while its key_id
// matches (no public-key operation). A different key_id is taken from this
// machine's stanza only when a rotation chain from the cached key proves it;
// with no cached key it is trusted on first use and its fingerprint printed.
// Anything else is a hard error (EXIT_CONFIG) naming `wayu secrets adopt
// --yes`.
//
// Version 1 stays valid: a store becomes version 2 only on opt-in (the first
// `recipient add` / `recovery add`), with a backup, a verify step and a
// one-time notice.

package wayu

import "core:crypto"
import "core:crypto/argon2id"
import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

SECRETS_MAX_ROTATIONS :: 16
SECRETS_KEY_ID_LEN :: 16 // hex digits
SECRETS_RECIPIENT_NAME_MAX :: 64
SECRETS_RECOVERY_KDF :: "argon2id"
SECRETS_RECOVERY_MIN_PASSPHRASE :: 12
SECRETS_RECOVERY_SALT_SIZE :: 16

// argon2id cost of a new recovery stanza (RFC 9106's memory-constrained
// recommendation: 64 MiB, 3 passes, 4 lanes).
SECRETS_RECOVERY_PARAMS :: argon2id.Parameters {
	memory_size = 64 * 1024,
	passes      = 3,
	parallelism = 4,
}

// Bounds a stored recovery stanza's parameters must meet (a synced file
// must not make `recovery unlock` allocate gigabytes or spin for minutes).
@(private = "file")
RECOVERY_MAX_MEMORY :: 1024 * 1024 // KiB (1 GiB)
@(private = "file")
RECOVERY_MAX_PASSES :: 16
@(private = "file")
RECOVERY_MAX_LANES :: 16

@(private = "file")
STANZA_BODY_SIZE :: SECRETS_KEY_SIZE + chacha20poly1305.TAG_SIZE
@(private = "file")
ROTATION_PROOF_SIZE :: ed25519.PUBLIC_KEY_SIZE + ed25519.SIGNATURE_SIZE
@(private = "file")
RECOVERY_IDENTITY_SIZE :: chacha20poly1305.IV_SIZE + AGE_KEY_SIZE + chacha20poly1305.TAG_SIZE
// The stanza-derivation label of the recovery stanza (names never hold NUL).
@(private = "file")
RECOVERY_LABEL :: "\x00recovery"

Secret_Recipient :: struct {
	name:      string,
	recipient: string, // age1…
	stanza:    string, // "<b64 share> <b64 body>" (unpadded)
}

Secret_Rotation :: struct {
	from:  string, // key_id
	to:    string, // key_id
	proof: string, // base64(VK_to || signature)
}

Secret_Recovery :: struct {
	recipient: string, // age1… of the recovery identity ("" = none)
	stanza:    string,
	salt:      string, // base64, 16 bytes
	identity:  string, // base64(nonce || sealed X25519 scalar || tag)
	m, t, p:   u32, // argon2id memory (KiB), passes, lanes
}

// Free the version 2 header of a store.
secrets_store_header_destroy :: proc(s: ^Secrets_Store) {
	delete(s.key_id)
	s.key_id = ""
	for r in s.recipients {
		delete(r.name)
		delete(r.recipient)
		delete(r.stanza)
	}
	delete(s.recipients)
	s.recipients = nil
	for r in s.rotations {
		delete(r.from)
		delete(r.to)
		delete(r.proof)
	}
	delete(s.rotations)
	s.rotations = nil
	secrets_recovery_destroy(&s.recovery)
}

secrets_recovery_destroy :: proc(r: ^Secret_Recovery) {
	delete(r.recipient)
	delete(r.stanza)
	delete(r.salt)
	delete(r.identity)
	r^ = {}
}

secrets_recipient_find :: proc(s: ^Secrets_Store, name: string) -> int {
	for r, i in s.recipients {
		if r.name == name {
			return i
		}
	}
	return -1
}

secrets_recipient_find_key :: proc(s: ^Secrets_Store, recipient: string) -> int {
	for r, i in s.recipients {
		if r.recipient == recipient {
			return i
		}
	}
	return -1
}

// A recipient name: 1-64 of [A-Za-z0-9._-].
secrets_recipient_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > SECRETS_RECIPIENT_NAME_MAX {
		return false
	}
	for i in 0 ..< len(name) {
		c := name[i]
		ok :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '.' ||
			c == '_' ||
			c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// This machine's default recipient name: `hostname -s` (gethostname up to
// the first dot), invalid characters replaced by '-'. Temp-allocated.
secrets_default_recipient_name :: proc() -> string {
	buf: [256]byte
	if posix.gethostname(raw_data(buf[:]), len(buf) - 1) != .OK {
		return "this-machine"
	}
	h := string(cstring(raw_data(buf[:])))
	if i := strings.index_byte(h, '.'); i >= 0 {
		h = h[:i]
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< min(len(h), SECRETS_RECIPIENT_NAME_MAX) {
		c := h[i]
		ok :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '.' ||
			c == '_' ||
			c == '-'
		strings.write_byte(&b, c if ok else '-')
	}
	name := strings.to_string(b)
	return name if len(name) > 0 else "this-machine"
}

// ---------------------------------------------------------------------------
// Derivations
// ---------------------------------------------------------------------------

@(private = "file")
hkdf_from_key :: proc(key: [SECRETS_KEY_SIZE]byte, info: string, dst: []byte) {
	k := key
	defer crypto.zero_explicit(&k, size_of(k))
	hkdf.extract_and_expand(.SHA256, nil, k[:], transmute([]byte)info, dst)
}

// The data key's id / fingerprint: 16 hex digits (temp-allocated).
secrets_key_id :: proc(key: [SECRETS_KEY_SIZE]byte) -> string {
	out: [8]byte
	hkdf_from_key(key, "wayu/secrets/key-id", out[:])
	return string(hex.encode(out[:], context.temp_allocator))
}

@(private = "file")
key_id_valid :: proc(id: string) -> bool {
	if len(id) != SECRETS_KEY_ID_LEN {
		return false
	}
	for i in 0 ..< len(id) {
		c := id[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// The rotation signing key of a data key.
@(private = "file")
rotation_signing_key :: proc(key: [SECRETS_KEY_SIZE]byte, priv: ^ed25519.Private_Key) {
	seed: [32]byte
	defer crypto.zero_explicit(&seed, size_of(seed))
	hkdf_from_key(key, "wayu/secrets/rotate-sign", seed[:])
	_ = ed25519.private_key_set_bytes(priv, seed[:]) // a 32-byte seed always succeeds
}

// The public rotation verification key of a data key.
secrets_rotation_vk :: proc(key: [SECRETS_KEY_SIZE]byte) -> (vk: [32]byte) {
	priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&priv)
	rotation_signing_key(key, &priv)
	ed25519.private_key_public_bytes(&priv, vk[:])
	return
}

@(private = "file")
rotation_message :: proc(from, to: string, vk_to: []byte) -> []byte {
	return(
		transmute([]byte)strings.concatenate(
			{"wayu-secrets-rotate\x00", from, "\x00", to, "\x00", string(vk_to)},
			context.temp_allocator,
		) \
	)
}

// The rotation entry proving to_key to holders of from_key (heap strings).
secrets_rotation_make :: proc(from_key, to_key: [SECRETS_KEY_SIZE]byte) -> Secret_Rotation {
	from := secrets_key_id(from_key)
	to := secrets_key_id(to_key)
	vk := secrets_rotation_vk(to_key)
	priv: ed25519.Private_Key
	defer ed25519.private_key_clear(&priv)
	rotation_signing_key(from_key, &priv)
	proof: [ROTATION_PROOF_SIZE]byte
	copy(proof[:32], vk[:])
	ed25519.sign(&priv, rotation_message(from, to, vk[:]), proof[32:])
	return {
		from = strings.clone(from),
		to = strings.clone(to),
		proof = base64.encode(proof[:], allocator = context.allocator),
	}
}

// Does a chain of at most `max_steps` rotations lead from from_key to
// to_key, each step signed by the previous key? (Pure: no keystore.)
secrets_rotation_chain_verify :: proc(
	rotations: []Secret_Rotation,
	from_key, to_key: [SECRETS_KEY_SIZE]byte,
	max_steps := SECRETS_MAX_ROTATIONS,
) -> bool {
	cur_id := secrets_key_id(from_key)
	cur_vk := secrets_rotation_vk(from_key)
	target_id := secrets_key_id(to_key)
	target_vk := secrets_rotation_vk(to_key)
	for steps := 0;; steps += 1 {
		if cur_id == target_id {
			return crypto.compare_constant_time(cur_vk[:], target_vk[:]) == 1
		}
		if steps >= max_steps {
			return false
		}
		advanced := false
		for r in rotations {
			if r.from != cur_id {
				continue
			}
			raw, err := base64.decode(
				r.proof,
				allocator = context.temp_allocator,
				options = {.Strict},
			)
			if err != nil || len(raw) != ROTATION_PROOF_SIZE {
				continue
			}
			pub: ed25519.Public_Key
			if !ed25519.public_key_set_bytes(&pub, cur_vk[:]) {
				return false
			}
			if !ed25519.verify(&pub, rotation_message(r.from, r.to, raw[:32]), raw[32:]) {
				continue
			}
			cur_id = r.to
			copy(cur_vk[:], raw[:32])
			advanced = true
			break
		}
		if !advanced {
			return false
		}
	}
}

// ---------------------------------------------------------------------------
// Stanzas
// ---------------------------------------------------------------------------

@(private = "file")
b64_raw :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	return base64.encode(data, allocator = allocator, options = {.No_Padding})
}

@(private = "file")
b64_raw_decode :: proc(s: string) -> ([]byte, bool) {
	out, err := base64.decode(
		s,
		allocator = context.temp_allocator,
		options = {.Strict, .No_Padding},
	)
	return out, err == nil
}

// Split "<share> <body>" (unpadded base64, 32 and 48 bytes; temp).
secrets_stanza_split :: proc(stanza: string) -> (share, body: []byte, ok: bool) {
	sp := strings.index_byte(stanza, ' ')
	if sp < 0 || strings.count(stanza, " ") != 1 {
		return
	}
	a, aok := b64_raw_decode(stanza[:sp])
	b, bok := b64_raw_decode(stanza[sp + 1:])
	if !aok || !bok || len(a) != AGE_KEY_SIZE || len(b) != STANZA_BODY_SIZE {
		return
	}
	return a, b, true
}

// The stanza wrapping `key` to `recipient` under `label` (the recipient's
// name, or RECOVERY_LABEL): deterministic, so a key holder can check it.
// Heap-allocated; ok = false for an invalid or low-order recipient.
secrets_stanza_make :: proc(
	key: [SECRETS_KEY_SIZE]byte,
	label, recipient: string,
) -> (
	stanza: string,
	ok: bool,
) {
	pub, rerr := age_recipient_decode(recipient)
	if len(rerr) > 0 {
		return "", false
	}
	eph: [AGE_KEY_SIZE]byte
	defer crypto.zero_explicit(&eph, size_of(eph))
	info := strings.concatenate(
		{"wayu/secrets/stanza\x00", label, "\x00", recipient},
		context.temp_allocator,
	)
	hkdf_from_key(key, info, eph[:])
	k := key
	defer crypto.zero_explicit(&k, size_of(k))
	share, body, wok := age_x25519_wrap(k[:], pub, eph, context.temp_allocator)
	if !wok {
		return "", false
	}
	return strings.concatenate({b64_raw(share[:]), " ", b64_raw(body)}), true
}

// Unwrap a stanza with an identity.
secrets_stanza_open :: proc(
	identity: [AGE_KEY_SIZE]byte,
	stanza: string,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
) {
	share, body, sok := secrets_stanza_split(stanza)
	if !sok {
		return
	}
	if !age_x25519_unwrap(identity, share, body, key[:]) {
		return key, false
	}
	return key, true
}

// The first recipient (or "recovery") whose stanza is not the one `key`
// gives: "" when all match. A mismatch means the entry was not written by
// wayu with this key (injected, renamed, swapped).
secrets_recipients_check :: proc(s: ^Secrets_Store, key: [SECRETS_KEY_SIZE]byte) -> string {
	for r in s.recipients {
		want, ok := secrets_stanza_make(key, r.name, r.recipient)
		same := ok && want == r.stanza
		delete(want)
		if !same {
			return r.name
		}
	}
	if len(s.recovery.recipient) > 0 {
		want, ok := secrets_stanza_make(key, RECOVERY_LABEL, s.recovery.recipient)
		same := ok && want == s.recovery.stanza
		delete(want)
		if !same {
			return "recovery"
		}
	}
	return ""
}

// secrets_recipients_check, exiting EXIT_CONFIG with the fix on a mismatch.
secrets_recipients_check_or_exit :: proc(s: ^Secrets_Store, key: [SECRETS_KEY_SIZE]byte) {
	bad := secrets_recipients_check(s, key)
	if len(bad) == 0 {
		return
	}
	fix :=
		"wayu secrets recovery rm --yes" if \
			bad == "recovery" else \
			fmt.tprintf("wayu secrets recipient rm %s --yes", bad)
	print_error_simple(
		"%s: the stanza of %s was not written by wayu with data key %s (an entry added or changed by hand, or a tampered file): nothing was changed. Check the file's history; to drop the entry, run: %s",
		secrets_store_path(),
		bad,
		s.key_id,
		fix,
	)
	wayu_exit(EXIT_CONFIG)
}

// Re-wrap `s` to new_key: every recipient's and the recovery stanza, a
// rotation proof from old_key appended (oldest dropped past 16), key_id.
secrets_store_rewrap_rotate :: proc(
	s: ^Secrets_Store,
	old_key, new_key: [SECRETS_KEY_SIZE]byte,
) -> (
	ok: bool,
	err: string,
) {
	stanzas := make([]string, len(s.recipients), context.temp_allocator)
	for r, i in s.recipients {
		st, sok := secrets_stanza_make(new_key, r.name, r.recipient)
		if !sok {
			for x in stanzas[:i] {delete(x)}
			return false, fmt.tprintf("cannot wrap the new key to %s (%s)", r.name, r.recipient)
		}
		stanzas[i] = st
	}
	rec_stanza: string
	if len(s.recovery.recipient) > 0 {
		st, sok := secrets_stanza_make(new_key, RECOVERY_LABEL, s.recovery.recipient)
		if !sok {
			for x in stanzas {delete(x)}
			return false, "cannot wrap the new key to the recovery stanza"
		}
		rec_stanza = st
	}
	for &r, i in s.recipients {
		delete(r.stanza)
		r.stanza = stanzas[i]
	}
	if len(rec_stanza) > 0 {
		delete(s.recovery.stanza)
		s.recovery.stanza = rec_stanza
	}
	append(&s.rotations, secrets_rotation_make(old_key, new_key))
	for len(s.rotations) > SECRETS_MAX_ROTATIONS {
		r := s.rotations[0]
		delete(r.from)
		delete(r.to)
		delete(r.proof)
		ordered_remove(&s.rotations, 0)
	}
	delete(s.key_id)
	s.key_id = strings.clone(secrets_key_id(new_key))
	return true, ""
}

// Add (or, with the same name, replace) a recipient wrapped to `key`.
secrets_recipient_put :: proc(
	s: ^Secrets_Store,
	key: [SECRETS_KEY_SIZE]byte,
	name, recipient: string,
) -> bool {
	st, ok := secrets_stanza_make(key, name, recipient)
	if !ok {
		return false
	}
	if i := secrets_recipient_find(s, name); i >= 0 {
		delete(s.recipients[i].recipient)
		delete(s.recipients[i].stanza)
		s.recipients[i].recipient = strings.clone(recipient)
		s.recipients[i].stanza = st
		return true
	}
	append(
		&s.recipients,
		Secret_Recipient {
			name = strings.clone(name),
			recipient = strings.clone(recipient),
			stanza = st,
		},
	)
	return true
}

// Turn a version 1 store into version 2 in memory: `key` (the 7.0 master
// key) becomes the data key, unchanged, wrapped to this machine. Values are
// untouched.
secrets_store_upgrade :: proc(
	s: ^Secrets_Store,
	key: [SECRETS_KEY_SIZE]byte,
	self_name: string,
	self_recipient: string,
) -> bool {
	s.version = SECRETS_VERSION_MULTI
	delete(s.key_id)
	s.key_id = strings.clone(secrets_key_id(key))
	return secrets_recipient_put(s, key, self_name, self_recipient)
}

// ---------------------------------------------------------------------------
// Recovery stanza (argon2id passphrase)
// ---------------------------------------------------------------------------

@(private = "file")
recovery_aad :: proc(recipient: string) -> []byte {
	return(
		transmute([]byte)strings.concatenate(
			{"wayu-secrets-recovery\x00", recipient},
			context.temp_allocator,
		) \
	)
}

// argon2id(passphrase, salt) → 32-byte key-encryption key. ok = false when
// the memory can't be allocated.
secrets_recovery_kek :: proc(
	passphrase: string,
	salt: []byte,
	params: argon2id.Parameters,
) -> (
	kek: [32]byte,
	ok: bool,
) {
	p := params
	if argon2id.derive(&p, transmute([]byte)passphrase, salt, kek[:]) != nil {
		crypto.zero_explicit(&kek, size_of(kek))
		return kek, false
	}
	return kek, true
}

// A new recovery stanza for `key` under `passphrase` (heap strings).
secrets_recovery_make :: proc(
	key: [SECRETS_KEY_SIZE]byte,
	passphrase: string,
	params := SECRETS_RECOVERY_PARAMS,
) -> (
	rec: Secret_Recovery,
	ok: bool,
) {
	rid: [AGE_KEY_SIZE]byte
	defer crypto.zero_explicit(&rid, size_of(rid))
	crypto.rand_bytes(rid[:])
	recipient := age_recipient_encode(age_identity_public(rid))
	salt: [SECRETS_RECOVERY_SALT_SIZE]byte
	crypto.rand_bytes(salt[:])
	kek, kok := secrets_recovery_kek(passphrase, salt[:], params)
	defer crypto.zero_explicit(&kek, size_of(kek))
	if !kok {
		return {}, false
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, kek[:])
	defer chacha20poly1305.reset(&ctx)
	sealed: [RECOVERY_IDENTITY_SIZE]byte
	nonce := sealed[:chacha20poly1305.IV_SIZE]
	crypto.rand_bytes(nonce)
	chacha20poly1305.seal(
		&ctx,
		sealed[chacha20poly1305.IV_SIZE:chacha20poly1305.IV_SIZE + AGE_KEY_SIZE],
		sealed[chacha20poly1305.IV_SIZE + AGE_KEY_SIZE:],
		nonce,
		recovery_aad(recipient),
		rid[:],
	)
	stanza, sok := secrets_stanza_make(key, RECOVERY_LABEL, recipient)
	if !sok {
		return {}, false
	}
	return {
			recipient = strings.clone(recipient),
			stanza = stanza,
			salt = base64.encode(salt[:], allocator = context.allocator),
			identity = base64.encode(sealed[:], allocator = context.allocator),
			m = params.memory_size,
			t = params.passes,
			p = params.parallelism,
		},
		true
}

// The data key from a recovery stanza and its passphrase. wrong_passphrase
// = the identity did not open; otherwise !ok means the stanza is broken.
secrets_recovery_unlock :: proc(
	rec: ^Secret_Recovery,
	passphrase: string,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
	wrong_passphrase: bool,
) {
	salt, serr := base64.decode(rec.salt, allocator = context.temp_allocator, options = {.Strict})
	sealed, ierr := base64.decode(
		rec.identity,
		allocator = context.temp_allocator,
		options = {.Strict},
	)
	if serr != nil || ierr != nil || len(sealed) != RECOVERY_IDENTITY_SIZE {
		return
	}
	kek, kok := secrets_recovery_kek(
		passphrase,
		salt,
		{memory_size = rec.m, passes = rec.t, parallelism = rec.p},
	)
	defer crypto.zero_explicit(&kek, size_of(kek))
	if !kok {
		return
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, kek[:])
	defer chacha20poly1305.reset(&ctx)
	rid: [AGE_KEY_SIZE]byte
	defer crypto.zero_explicit(&rid, size_of(rid))
	if !chacha20poly1305.open(
		&ctx,
		rid[:],
		sealed[:chacha20poly1305.IV_SIZE],
		recovery_aad(rec.recipient),
		sealed[chacha20poly1305.IV_SIZE:chacha20poly1305.IV_SIZE + AGE_KEY_SIZE],
		sealed[chacha20poly1305.IV_SIZE + AGE_KEY_SIZE:],
	) {
		return key, false, true
	}
	if age_recipient_encode(age_identity_public(rid)) != rec.recipient {
		return
	}
	k, uok := secrets_stanza_open(rid, rec.stanza)
	if !uok {
		return
	}
	return k, true, false
}

// ---------------------------------------------------------------------------
// secrets.json version 2 header
// ---------------------------------------------------------------------------

// Parse and check the version 2 fields into `s` (strict: every field
// known, required ones present, names / recipients unique and valid, at
// most 16 rotations). err is temp-allocated.
secrets_store_parse_header :: proc(doc: json.Object, s: ^Secrets_Store) -> string {
	kid, kid_ok := doc["key_id"].(json.String)
	if !kid_ok || !key_id_valid(kid) {
		return "\"key_id\" must be 16 lower-case hex digits"
	}
	s.key_id = strings.clone(kid)

	list, l_ok := doc["recipients"].(json.Array)
	if !l_ok {
		return "\"recipients\" must be a list of {\"name\", \"recipient\", \"stanza\"}"
	}
	if len(list) == 0 {
		return "\"recipients\" is empty (a version 2 store has at least one machine)"
	}
	for item in list {
		obj, o_ok := item.(json.Object)
		if !o_ok {
			return "\"recipients\" must be a list of {\"name\", \"recipient\", \"stanza\"}"
		}
		for k in obj {
			switch k {
			case "name", "recipient", "stanza":
			case:
				return fmt.tprintf("unknown field %q in a recipient", k)
			}
		}
		name, n_ok := obj["name"].(json.String)
		recipient, r_ok := obj["recipient"].(json.String)
		stanza, s_ok := obj["stanza"].(json.String)
		if !n_ok || !r_ok || !s_ok {
			return "a recipient needs string \"name\", \"recipient\" and \"stanza\""
		}
		if !secrets_recipient_name_valid(name) {
			return fmt.tprintf("recipient name %q is not valid (1-64 of A-Z a-z 0-9 . _ -)", name)
		}
		if _, rerr := age_recipient_decode(recipient); len(rerr) > 0 {
			return fmt.tprintf("recipient %s: %s", name, rerr)
		}
		if _, _, sp_ok := secrets_stanza_split(stanza); !sp_ok {
			return fmt.tprintf(
				"recipient %s: malformed stanza (expected \"<share> <body>\", unpadded base64 of 32 and 48 bytes)",
				name,
			)
		}
		if secrets_recipient_find(s, name) >= 0 {
			return fmt.tprintf("recipient name %q is listed twice", name)
		}
		if i := secrets_recipient_find_key(s, recipient); i >= 0 {
			return fmt.tprintf(
				"recipient %s is listed twice (as %s and %s)",
				recipient,
				s.recipients[i].name,
				name,
			)
		}
		append(
			&s.recipients,
			Secret_Recipient {
				name = strings.clone(name),
				recipient = strings.clone(recipient),
				stanza = strings.clone(stanza),
			},
		)
	}

	if rv, has := doc["rotations"]; has {
		rl, rl_ok := rv.(json.Array)
		if !rl_ok {
			return "\"rotations\" must be a list of {\"from\", \"to\", \"proof\"}"
		}
		if len(rl) > SECRETS_MAX_ROTATIONS {
			return fmt.tprintf(
				"\"rotations\" has %d entries (at most %d)",
				len(rl),
				SECRETS_MAX_ROTATIONS,
			)
		}
		for item in rl {
			obj, o_ok := item.(json.Object)
			if !o_ok {
				return "\"rotations\" must be a list of {\"from\", \"to\", \"proof\"}"
			}
			for k in obj {
				switch k {
				case "from", "to", "proof":
				case:
					return fmt.tprintf("unknown field %q in a rotation", k)
				}
			}
			from, f_ok := obj["from"].(json.String)
			to, t_ok := obj["to"].(json.String)
			proof, p_ok := obj["proof"].(json.String)
			if !f_ok || !t_ok || !p_ok || !key_id_valid(from) || !key_id_valid(to) {
				return(
					"a rotation needs \"from\" and \"to\" key ids (16 hex digits) and a \"proof\"" \
				)
			}
			raw, derr := base64.decode(
				proof,
				allocator = context.temp_allocator,
				options = {.Strict},
			)
			if derr != nil || len(raw) != ROTATION_PROOF_SIZE {
				return fmt.tprintf("rotation %s -> %s: malformed proof", from, to)
			}
			append(
				&s.rotations,
				Secret_Rotation {
					from = strings.clone(from),
					to = strings.clone(to),
					proof = strings.clone(proof),
				},
			)
		}
	}

	if rv, has := doc["recovery"]; has {
		obj, o_ok := rv.(json.Object)
		if !o_ok {
			return "\"recovery\" must be an object"
		}
		for k in obj {
			switch k {
			case "recipient", "stanza", "kdf", "m", "t", "p", "salt", "identity":
			case:
				return fmt.tprintf("unknown field %q in \"recovery\"", k)
			}
		}
		recipient, r_ok := obj["recipient"].(json.String)
		stanza, s_ok := obj["stanza"].(json.String)
		kdf, k_ok := obj["kdf"].(json.String)
		salt, sa_ok := obj["salt"].(json.String)
		ident, i_ok := obj["identity"].(json.String)
		m, m_ok := obj["m"].(json.Integer)
		t, t_ok := obj["t"].(json.Integer)
		p, p_ok := obj["p"].(json.Integer)
		if !r_ok || !s_ok || !k_ok || !sa_ok || !i_ok || !m_ok || !t_ok || !p_ok {
			return(
				"\"recovery\" needs \"recipient\", \"stanza\", \"kdf\", \"m\", \"t\", \"p\", \"salt\" and \"identity\"" \
			)
		}
		if kdf != SECRETS_RECOVERY_KDF {
			return fmt.tprintf(
				"\"recovery\": unsupported kdf %q (expected %q)",
				kdf,
				SECRETS_RECOVERY_KDF,
			)
		}
		if p < 1 ||
		   p > RECOVERY_MAX_LANES ||
		   t < 1 ||
		   t > RECOVERY_MAX_PASSES ||
		   m < 8 * p ||
		   m > RECOVERY_MAX_MEMORY {
			return(
				"\"recovery\": argon2id parameters out of range (m 8*p..1048576 KiB, t 1..16, p 1..16)" \
			)
		}
		if _, rerr := age_recipient_decode(recipient); len(rerr) > 0 {
			return fmt.tprintf("\"recovery\": %s", rerr)
		}
		if secrets_recipient_find_key(s, recipient) >= 0 {
			return "\"recovery\": its recipient is also a machine's"
		}
		if _, _, sp_ok := secrets_stanza_split(stanza); !sp_ok {
			return "\"recovery\": malformed stanza"
		}
		sraw, serr := base64.decode(salt, allocator = context.temp_allocator, options = {.Strict})
		iraw, ierr := base64.decode(ident, allocator = context.temp_allocator, options = {.Strict})
		if serr != nil ||
		   len(sraw) != SECRETS_RECOVERY_SALT_SIZE ||
		   ierr != nil ||
		   len(iraw) != RECOVERY_IDENTITY_SIZE {
			return "\"recovery\": malformed \"salt\" or \"identity\""
		}
		s.recovery = Secret_Recovery {
			recipient = strings.clone(recipient),
			stanza    = strings.clone(stanza),
			salt      = strings.clone(salt),
			identity  = strings.clone(ident),
			m         = u32(m),
			t         = u32(t),
			p         = u32(p),
		}
	}
	return ""
}

// The version 2 header lines (after "cipher"): one recipient / rotation per
// line, recipients sorted by name.
secrets_store_format_header :: proc(b: ^strings.Builder, s: ^Secrets_Store) {
	slice.sort_by(s.recipients[:], proc(a, b: Secret_Recipient) -> bool {return a.name < b.name})
	fmt.sbprintfln(b, `  "key_id": "%s",`, s.key_id)
	strings.write_string(b, "  \"recipients\": [\n")
	for r, i in s.recipients {
		fmt.sbprintf(
			b,
			`    {{"name": "%s", "recipient": "%s", "stanza": "%s"}}`,
			r.name,
			r.recipient,
			r.stanza,
		)
		strings.write_string(b, ",\n" if i + 1 < len(s.recipients) else "\n")
	}
	strings.write_string(b, "  ],\n")
	if len(s.recovery.recipient) > 0 {
		r := s.recovery
		fmt.sbprintfln(
			b,
			`  "recovery": {{"recipient": "%s", "stanza": "%s", "kdf": "%s", "m": %d, "t": %d, "p": %d, "salt": "%s", "identity": "%s"}},`,
			r.recipient,
			r.stanza,
			SECRETS_RECOVERY_KDF,
			r.m,
			r.t,
			r.p,
			r.salt,
			r.identity,
		)
	}
	if len(s.rotations) > 0 {
		strings.write_string(b, "  \"rotations\": [\n")
		for r, i in s.rotations {
			fmt.sbprintf(
				b,
				`    {{"from": "%s", "to": "%s", "proof": "%s"}}`,
				r.from,
				r.to,
				r.proof,
			)
			strings.write_string(b, ",\n" if i + 1 < len(s.rotations) else "\n")
		}
		strings.write_string(b, "  ],\n")
	}
}

// ---------------------------------------------------------------------------
// Data key of a version 2 store (pinning)
// ---------------------------------------------------------------------------

// "this machine is not a recipient" with the commands that fix it.
@(private = "file")
not_recipient_error :: proc(recipient: string) -> string {
	if len(recipient) == 0 {
		return fmt.tprintf(
			"this machine is not a recipient of %s; run 'wayu secrets identity' and add it from a machine that is",
			secrets_store_path(),
		)
	}
	return fmt.tprintf(
		"this machine is not a recipient of %s; run on a machine that is: wayu secrets recipient add %s --name %s",
		secrets_store_path(),
		recipient,
		secrets_default_recipient_name(),
	)
}

// The data key in this machine's stanza (identity from the keystore).
// Every failure is an error naming its fix.
secrets_key_from_own_stanza :: proc(
	s: ^Secrets_Store,
	backend: Secrets_Backend,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	name: string,
	ok: bool,
	err: string,
) {
	id, status, msg := keystore_identity_load(backend)
	defer crypto.zero_explicit(&id, size_of(id))
	switch status {
	case .OK:
	case .MISSING:
		return key, "", false, not_recipient_error("")
	case .UNAVAILABLE, .INVALID:
		return key, "", false, msg
	}
	recipient := age_recipient_encode(age_identity_public(id))
	i := secrets_recipient_find_key(s, recipient)
	if i < 0 {
		return key, "", false, not_recipient_error(recipient)
	}
	name = s.recipients[i].name
	k, uok := secrets_stanza_open(id, s.recipients[i].stanza)
	if !uok {
		return key, name, false, fmt.tprintf(
			"this machine is listed in %s as %s but cannot unwrap its stanza (a tampered or corrupt file): restore it with 'wayu backup restore entries --yes', or on another machine run: wayu secrets recipient rm %s --yes && wayu secrets recipient add %s --name %s",
			secrets_store_path(),
			name,
			name,
			recipient,
			name,
		)
	}
	if got := secrets_key_id(k); got != s.key_id {
		crypto.zero_explicit(&k, size_of(k))
		return key, name, false, fmt.tprintf(
			"%s: this machine's stanza holds data key %s, not key_id %s (a tampered or corrupt file): restore it with 'wayu backup restore entries --yes'",
			secrets_store_path(),
			got,
			s.key_id,
		)
	}
	return k, name, true, ""
}

// The data key of a version 2 store. The cached key while its id matches
// key_id (no X25519); else this machine's stanza, adopted (and cached) only
// when a rotation chain from the cached key proves it, or on first use when
// nothing is cached. Under --dry-run nothing is cached.
secrets_key_multi :: proc(
	s: ^Secrets_Store,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
	err: string,
) {
	backend := secrets_backend_active()
	cached, status, msg := secrets_key_load(backend)
	defer crypto.zero_explicit(&cached, size_of(cached))
	if status == .OK && secrets_key_id(cached) == s.key_id {
		return cached, true, ""
	}
	if status == .UNAVAILABLE || status == .INVALID {
		return key, false, msg
	}
	k, _, sok, serr := secrets_key_from_own_stanza(s, backend)
	if !sok {
		return key, false, serr
	}
	if status == .MISSING {
		if !wayu.dry_run {
			if saved, sv := keystore_save(backend, k, false); !saved {
				crypto.zero_explicit(&k, size_of(k))
				return key, false, sv
			}
		}
		fmt.eprintfln(
			"wayu: adopted data key %s (first use on this machine; compare it with 'wayu secrets recipient list' on another machine)",
			s.key_id,
		)
		return k, true, ""
	}
	old_id := secrets_key_id(cached)
	if !secrets_rotation_chain_verify(s.rotations[:], cached, k) {
		crypto.zero_explicit(&k, size_of(k))
		return key, false, fmt.tprintf(
			"%s: data key %s is not proven by a rotation from this machine's key %s (the file was tampered with, or the key rotated more than %d times while this machine was offline); compare %s with 'wayu secrets recipient list' on another machine, then run: wayu secrets adopt --yes",
			secrets_store_path(),
			s.key_id,
			old_id,
			SECRETS_MAX_ROTATIONS,
			s.key_id,
		)
	}
	if !wayu.dry_run {
		if saved, sv := keystore_save(backend, k, true); !saved {
			crypto.zero_explicit(&k, size_of(k))
			return key, false, sv
		}
	}
	fmt.eprintfln("wayu: adopted data key %s (rotation from %s verified)", s.key_id, old_id)
	return k, true, ""
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

// <data>/run/notice-multi-machine-secrets: the experimental notice was shown.
@(private = "file")
multi_notice_path :: proc() -> string {
	return fmt.tprintf("%s/notice-multi-machine-secrets", secrets_private_run_dir())
}

// One-time stderr notice: multi-machine secrets are experimental.
@(private = "file")
secrets_multi_notice :: proc() {
	path := multi_notice_path()
	if os.exists(path) {
		return
	}
	fmt.eprintln(
		"wayu: multi-machine secrets are experimental: the commands and the version 2 secrets.json format may change in a minor release (a format change still migrates automatically; see docs/STABILITY.md). This notice is shown once.",
	)
	if wayu.dry_run {
		return
	}
	if ok, _ := private_dir_ensure(secrets_private_run_dir()); ok {
		if write_file_atomic(path, {}) == nil {
			restrict_file_mode(path)
		}
	}
}

// Value of `--name NAME` / `--name=NAME` in args, and the args without it.
// Exits EXIT_USAGE for a flag without a value, EXIT_DATAERR for a bad name.
@(private = "file")
take_name_flag :: proc(args: []string) -> (name: string, rest: []string) {
	out := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--name":
			if i + 1 >= len(args) {
				print_error_simple("--name needs a value (1-64 of A-Z a-z 0-9 . _ -)")
				wayu_exit(EXIT_USAGE)
			}
			name = args[i + 1]
			i += 1
		case strings.has_prefix(a, "--name="):
			name = strings.trim_prefix(a, "--name=")
		case:
			append(&out, a)
		}
	}
	if len(name) > 0 || slice.contains(args, "--name=") {
		if !secrets_recipient_name_valid(name) {
			print_error_simple("Invalid recipient name %q (1-64 of A-Z a-z 0-9 . _ -)", name)
			wayu_exit(EXIT_DATAERR)
		}
	}
	return name, out[:]
}

@(private = "file")
need_yes :: proc(command: string) {
	if !wayu.yes_flag {
		print_error_simple("This operation requires confirmation: wayu secrets %s --yes", command)
		wayu_exit(EXIT_USAGE)
	}
}

// Exit with a keystore save error: I/O for the file backend, else config.
@(private = "file")
exit_keystore_save_error :: proc(backend: Secrets_Backend, msg: string) -> ! {
	if secrets_backend_resolve(backend) == .FILE {
		exit_with_secret_error(fmt.tprintf("I/O error: %s", msg))
	}
	exit_with_secret_error(msg)
}

// This machine's identity, created when missing (created = true).
@(private = "file")
identity_load_or_create :: proc(
	backend: Secrets_Backend,
) -> (
	id: [AGE_KEY_SIZE]byte,
	created: bool,
) {
	k, status, msg := keystore_identity_load(backend)
	switch status {
	case .OK:
		return k, false
	case .MISSING:
	case .UNAVAILABLE, .INVALID:
		exit_with_secret_error(msg)
	}
	crypto.rand_bytes(id[:])
	if ok, serr := keystore_identity_save(backend, id); !ok {
		crypto.zero_explicit(&id, size_of(id))
		exit_keystore_save_error(backend, serr)
	}
	return id, true
}

// Re-read secrets.json and check it is the version 2 store just written:
// key_id is `key`'s, this machine's stanza unwraps to `key`, every value
// opens.
@(private = "file")
secrets_store_verify_written :: proc(
	key: [SECRETS_KEY_SIZE]byte,
	identity: [AGE_KEY_SIZE]byte,
) -> (
	ok: bool,
	why: string,
) {
	data, rerr := os.read_entire_file_from_path(secrets_store_path(), context.allocator)
	if rerr != nil {
		return false, fmt.tprintf("cannot read it back: %v", rerr)
	}
	s, perr := secrets_store_parse(string(data))
	delete(data)
	defer secrets_store_destroy(&s)
	if len(perr) > 0 {
		return false, perr
	}
	if !secrets_store_is_multi(&s) || s.key_id != secrets_key_id(key) {
		return false, "key_id does not match the data key"
	}
	recipient := age_recipient_encode(age_identity_public(identity))
	i := secrets_recipient_find_key(&s, recipient)
	if i < 0 {
		return false, "this machine's stanza is missing"
	}
	k, uok := secrets_stanza_open(identity, s.recipients[i].stanza)
	k2 := key
	same := uok && crypto.compare_constant_time(k[:], k2[:]) == 1
	crypto.zero_explicit(&k, size_of(k))
	crypto.zero_explicit(&k2, size_of(k2))
	if !same {
		return false, "this machine's stanza does not unwrap to the data key"
	}
	for e in s.entries {
		v, dok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			return false, fmt.tprintf("%s does not decrypt", e.name)
		}
		secrets_wipe(v)
	}
	return true, ""
}

// Write a header change (caller holds the lock): backup + atomic write,
// then the verify step; on a verify failure secrets.json goes back to
// `snap` and wayu exits EXIT_IOERR.
@(private = "file")
secrets_store_save_verified :: proc(
	s: ^Secrets_Store,
	snap: ^Secrets_Store_Snapshot,
	key: [SECRETS_KEY_SIZE]byte,
	identity: [AGE_KEY_SIZE]byte,
) {
	if ok, err := secrets_store_save(s); !ok {
		secrets_store_snapshot_restore(snap)
		exit_with_secret_error(err)
	}
	if ok, why := secrets_store_verify_written(key, identity); !ok {
		secrets_store_snapshot_restore(snap)
		print_error_simple(
			"%s did not verify after writing (%s): it was put back as it was",
			secrets_store_path(),
			why,
		)
		wayu_exit(EXIT_IOERR)
	}
}

@(private = "file")
upgrade_notice :: proc() {
	fmt.eprintfln(
		"wayu: %s is now version 2 (multi-machine; a backup of version 1 was taken: wayu backup list). wayu 7.0 and older cannot read it: upgrade wayu on every machine that syncs it.",
		secrets_store_path(),
	)
}

// The data key for a header change: version 1 → the master key (created
// when the store holds no values); version 2 → pinned, and every stanza
// checked against it.
@(private = "file")
key_for_header_change :: proc(s: ^Secrets_Store) -> (key: [SECRETS_KEY_SIZE]byte) {
	ok: bool
	err: string
	key, ok, err = secrets_key_for_write(s)
	if !ok {
		exit_with_secret_error(err)
	}
	if secrets_store_is_multi(s) {
		secrets_recipients_check_or_exit(s, key)
	}
	return key
}

// `wayu secrets identity|recipient|adopt|recovery`.
handle_secrets_multi_command :: proc(action: Action, args: []string) {
	if wayu.json_output &&
	   !(action == .RECIPIENT && len(args) > 0 && (args[0] == "list" || args[0] == "ls")) {
		print_error_simple("--json is only supported by 'wayu secrets recipient list'")
		wayu_exit(EXIT_USAGE)
	}
	#partial switch action {
	case .IDENTITY:
		secrets_identity_command(args)
	case .ADOPT:
		secrets_adopt_command()
	case .RECIPIENT:
		if len(args) == 0 {
			print_error_simple("Usage: wayu secrets recipient list|add|rm|rename …")
			wayu_exit(EXIT_USAGE)
		}
		switch args[0] {
		case "list", "ls":
			secrets_recipient_list(args[1:])
		case "add":
			secrets_recipient_add(args[1:])
		case "rm", "remove":
			secrets_recipient_rm(args[1:])
		case "rename":
			secrets_recipient_rename(args[1:])
		case:
			print_error_simple(
				"Unknown recipient action '%s' (expected list, add, rm or rename)",
				args[0],
			)
			wayu_exit(EXIT_USAGE)
		}
	case .RECOVERY:
		if len(args) == 0 {
			print_error_simple("Usage: wayu secrets recovery add|rm|unlock")
			wayu_exit(EXIT_USAGE)
		}
		switch args[0] {
		case "add":
			secrets_recovery_add(args[1:])
		case "rm", "remove":
			secrets_recovery_rm(args[1:])
		case "unlock":
			secrets_recovery_unlock_command(args[1:])
		case:
			print_error_simple(
				"Unknown recovery action '%s' (expected add, rm or unlock)",
				args[0],
			)
			wayu_exit(EXIT_USAGE)
		}
	}
}

@(private = "file")
no_extra_args :: proc(args: []string, usage: string) {
	if len(args) > 0 {
		print_error_simple("Unexpected argument '%s'. Usage: %s", args[0], usage)
		wayu_exit(EXIT_USAGE)
	}
}

// `wayu secrets identity [--name NAME]`: print this machine's recipient on
// stdout (creating the identity once), and on stderr the command to run on
// a machine that reads the secrets.
@(private = "file")
secrets_identity_command :: proc(args: []string) {
	name, rest := take_name_flag(args)
	no_extra_args(rest, "wayu secrets identity [--name NAME]")
	if len(name) == 0 {
		name = secrets_default_recipient_name()
	}
	secrets_multi_notice()
	backend := secrets_backend_active()
	if wayu.dry_run {
		id, status, msg := keystore_identity_load(backend)
		defer crypto.zero_explicit(&id, size_of(id))
		switch status {
		case .OK:
			fmt.println(age_recipient_encode(age_identity_public(id)))
		case .MISSING:
			print_info(
				"[dry-run] Would create this machine's identity (%s)",
				SECRETS_BACKEND_NAMES[backend],
			)
		case .UNAVAILABLE, .INVALID:
			exit_with_secret_error(msg)
		}
		return
	}
	id, created := identity_load_or_create(backend)
	defer crypto.zero_explicit(&id, size_of(id))
	recipient := age_recipient_encode(age_identity_public(id))
	fmt.println(recipient)
	if created {
		fmt.eprintfln(
			"wayu: created this machine's identity (%s)",
			identity_key_file_path() if \
				secrets_backend_resolve(backend) == .FILE else \
				SECRETS_BACKEND_NAMES[backend],
		)
	}
	fmt.eprintfln(
		"To let this machine read the secrets, run on a machine that already does, then sync secrets.json:\n  wayu secrets recipient add %s --name %s",
		recipient,
		name,
	)
}

// `wayu secrets recipient list [--json]`.
@(private = "file")
secrets_recipient_list :: proc(args: []string) {
	no_extra_args(args, "wayu secrets recipient list [--json]")
	secrets_multi_notice()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	multi := secrets_store_is_multi(&s)
	self := ""
	if multi {
		id, status, msg := keystore_identity_load(secrets_backend_active())
		defer crypto.zero_explicit(&id, size_of(id))
		#partial switch status {
		case .OK:
			self = age_recipient_encode(age_identity_public(id))
		case .UNAVAILABLE, .INVALID:
			exit_with_secret_error(msg)
		}
	}
	if wayu.json_output {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"recipients": [`)
		for r, i in s.recipients {
			n := json_escape(r.name)
			fmt.sbprintf(
				&b,
				`%s{{"name": "%s", "recipient": "%s", "this_machine": %v}}`,
				", " if i > 0 else "",
				n,
				r.recipient,
				r.recipient == self,
			)
			delete(n)
		}
		fmt.sbprintf(
			&b,
			`], "key_id": "%s", "recovery": %v}}`,
			s.key_id,
			len(s.recovery.recipient) > 0,
		)
		fmt.println(strings.to_string(b))
		return
	}
	if !multi {
		print_info(
			"secrets.json is version 1 (one machine): no recipients. Add another machine with: wayu secrets recipient add <age1…> --name NAME",
		)
		return
	}
	width := 0
	for r in s.recipients {width = max(width, len(r.name))}
	for r in s.recipients {
		fmt.printfln(
			"%-*s  %s%s",
			width,
			r.name,
			r.recipient,
			"  (this machine)" if r.recipient == self else "",
		)
	}
	fmt.printfln("data key: %s", s.key_id)
	if len(s.recovery.recipient) > 0 {
		fmt.println("recovery passphrase: set")
	}
}

// `wayu secrets recipient add <age1…> [--name NAME]`.
@(private = "file")
secrets_recipient_add :: proc(args: []string) {
	name, rest := take_name_flag(args)
	if len(rest) != 1 {
		print_error_simple("Usage: wayu secrets recipient add <age1…> [--name NAME]")
		wayu_exit(EXIT_USAGE)
	}
	recipient := rest[0]
	pub, rerr := age_recipient_decode(recipient)
	if len(rerr) > 0 {
		print_error_simple("%s: %s", recipient, rerr)
		wayu_exit(EXIT_DATAERR)
	}
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	backend := secrets_backend_active()

	id, istatus, imsg := keystore_identity_load(backend)
	defer crypto.zero_explicit(&id, size_of(id))
	if istatus == .UNAVAILABLE || istatus == .INVALID {
		exit_with_secret_error(imsg)
	}
	is_self := istatus == .OK && age_identity_public(id) == pub
	if len(name) == 0 {
		if !is_self {
			print_error_simple(
				"--name NAME is required for another machine's key: 'wayu secrets identity' on that machine prints the full command (its default name is its hostname)",
			)
			wayu_exit(EXIT_USAGE)
		}
		name = secrets_default_recipient_name()
	}
	migrating := !secrets_store_is_multi(&s)
	self_name := name if is_self else secrets_default_recipient_name()
	if migrating && !is_self && self_name == name {
		print_error_simple(
			"%s is this machine's name (its hostname), which the upgrade adds as a recipient: pick another --name for %s",
			name,
			recipient,
		)
		wayu_exit(EXIT_DATAERR)
	}
	if i := secrets_recipient_find(&s, name); i >= 0 {
		print_error_simple(
			"Recipient %s already exists (%s): pick another --name, or rename it with: wayu secrets recipient rename %s NEW",
			name,
			s.recipients[i].recipient,
			name,
		)
		wayu_exit(EXIT_DATAERR)
	}
	if i := secrets_recipient_find_key(&s, recipient); i >= 0 {
		print_error_simple(
			"%s is already a recipient, as %s (rename it with: wayu secrets recipient rename %s NEW)",
			recipient,
			s.recipients[i].name,
			s.recipients[i].name,
		)
		wayu_exit(EXIT_DATAERR)
	}
	if wayu.dry_run {
		if migrating {
			print_info(
				"[dry-run] Would upgrade %s to version 2 (backup first), add this machine as %s%s",
				secrets_store_path(),
				self_name,
				"" if is_self else fmt.tprintf(" and %s (%s)", name, recipient),
			)
		} else {
			print_info("[dry-run] Would add recipient %s (%s)", name, recipient)
		}
		return
	}

	key := key_for_header_change(&s)
	defer crypto.zero_explicit(&key, size_of(key))
	snap := secrets_store_snapshot()
	defer secrets_store_snapshot_destroy(&snap)
	if migrating {
		self_id, created := identity_load_or_create(backend)
		id = self_id
		crypto.zero_explicit(&self_id, size_of(self_id))
		if created {
			fmt.eprintln("wayu: created this machine's identity")
		}
		if !secrets_store_upgrade(
			&s,
			key,
			self_name,
			age_recipient_encode(age_identity_public(id)),
		) {
			exit_with_secret_error("cannot wrap the data key to this machine's identity")
		}
	}
	if !(migrating && is_self) {
		if !secrets_recipient_put(&s, key, name, recipient) {
			print_error_simple("%s: cannot wrap the data key to it (a low-order key)", recipient)
			wayu_exit(EXIT_DATAERR)
		}
	}
	if istatus != .OK && !migrating {
		// Version 2 already, but this machine has no identity: it read the
		// key from the cache; verify against the store without a stanza.
		if ok, err := secrets_store_save(&s); !ok {
			secrets_store_snapshot_restore(&snap)
			exit_with_secret_error(err)
		}
	} else {
		secrets_store_save_verified(&s, &snap, key, id)
	}
	if migrating {
		upgrade_notice()
	}
	print_success(
		"Recipient added: %s (%s). Sync secrets.json; that machine's next shell reads the secrets.",
		name,
		recipient,
	)
}

// `wayu secrets recipient rm NAME --yes`: drop the stanza, then rotate.
@(private = "file")
secrets_recipient_rm :: proc(args: []string) {
	if len(args) != 1 {
		print_error_simple("Usage: wayu secrets recipient rm NAME --yes")
		wayu_exit(EXIT_USAGE)
	}
	name := args[0]
	need_yes(fmt.tprintf("recipient rm %s", name))
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	if !secrets_store_is_multi(&s) {
		print_error_simple("No recipients: secrets.json is version 1 (one machine)")
		wayu_exit(EXIT_DATAERR)
	}
	i := secrets_recipient_find(&s, name)
	if i < 0 {
		print_error_simple("No recipient named %s (see wayu secrets recipient list)", name)
		wayu_exit(EXIT_DATAERR)
	}
	backend := secrets_backend_active()
	id, istatus, imsg := keystore_identity_load(backend)
	if istatus == .UNAVAILABLE || istatus == .INVALID {
		exit_with_secret_error(imsg)
	}
	is_self :=
		istatus == .OK &&
		age_recipient_encode(age_identity_public(id)) == s.recipients[i].recipient
	crypto.zero_explicit(&id, size_of(id))
	if is_self {
		print_error_simple(
			"%s is this machine: refusing to remove it here (this machine could no longer read the secrets); run it on another machine that reads them",
			name,
		)
		wayu_exit(EXIT_DATAERR)
	}
	if len(s.recipients) == 1 {
		print_error_simple("%s is the last recipient: refusing to remove it", name)
		wayu_exit(EXIT_DATAERR)
	}
	if wayu.dry_run {
		print_info(
			"[dry-run] Would remove recipient %s, create a new data key, re-encrypt %d secret(s) and wrap it to %d recipient(s)",
			name,
			len(s.entries),
			len(s.recipients) - 1,
		)
		return
	}
	old_key, kok, kerr := secrets_key_for_read(&s)
	if !kok {
		exit_with_secret_error(kerr)
	}
	defer crypto.zero_explicit(&old_key, size_of(old_key))
	secrets_recipients_check_or_exit(&s, old_key)

	r := s.recipients[i]
	delete(r.name)
	delete(r.recipient)
	delete(r.stanza)
	ordered_remove(&s.recipients, i)
	secrets_rotate_and_commit(&s, backend, old_key)
	print_success(
		"Removed recipient %s; new data key %s wrapped to %d recipient(s). %s already decrypted the old values: rotate those credentials upstream.",
		name,
		s.key_id,
		len(s.recipients),
		name,
	)
}

// New data key for `s` (values re-encrypted, stanzas re-wrapped, proof
// appended), committed crash-safe. Exits on failure.
@(private = "file")
secrets_rotate_and_commit :: proc(
	s: ^Secrets_Store,
	backend: Secrets_Backend,
	old_key: [SECRETS_KEY_SIZE]byte,
) {
	new_key := secrets_new_key()
	defer crypto.zero_explicit(&new_key, size_of(new_key))
	if ok, err := secrets_store_reencrypt(s, old_key, new_key); !ok {
		exit_with_secret_error(err)
	}
	if ok, err := secrets_store_rewrap_rotate(s, old_key, new_key); !ok {
		exit_with_secret_error(err)
	}
	secrets_store_commit_new_key(s, backend, old_key, new_key)
}

// `wayu secrets recipient rename OLD NEW`.
@(private = "file")
secrets_recipient_rename :: proc(args: []string) {
	if len(args) != 2 {
		print_error_simple("Usage: wayu secrets recipient rename OLD NEW")
		wayu_exit(EXIT_USAGE)
	}
	old, new := args[0], args[1]
	if !secrets_recipient_name_valid(new) {
		print_error_simple("Invalid recipient name %q (1-64 of A-Z a-z 0-9 . _ -)", new)
		wayu_exit(EXIT_DATAERR)
	}
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	if !secrets_store_is_multi(&s) {
		print_error_simple("No recipients: secrets.json is version 1 (one machine)")
		wayu_exit(EXIT_DATAERR)
	}
	i := secrets_recipient_find(&s, old)
	if i < 0 {
		print_error_simple("No recipient named %s (see wayu secrets recipient list)", old)
		wayu_exit(EXIT_DATAERR)
	}
	if old == new {
		print_info("%s already has that name", old)
		return
	}
	if secrets_recipient_find(&s, new) >= 0 {
		print_error_simple("Recipient %s already exists", new)
		wayu_exit(EXIT_DATAERR)
	}
	if wayu.dry_run {
		print_info("[dry-run] Would rename recipient %s to %s", old, new)
		return
	}
	key := key_for_header_change(&s)
	defer crypto.zero_explicit(&key, size_of(key))
	recipient := strings.clone(s.recipients[i].recipient, context.temp_allocator)
	r := s.recipients[i]
	delete(r.name)
	delete(r.recipient)
	delete(r.stanza)
	ordered_remove(&s.recipients, i)
	if !secrets_recipient_put(&s, key, new, recipient) {
		exit_with_secret_error("cannot re-wrap the data key")
	}
	if ok, err := secrets_store_save(&s); !ok {
		exit_with_secret_error(err)
	}
	print_success("Recipient renamed: %s -> %s", old, new)
}

// `wayu secrets adopt --yes`: take the data key from this machine's
// stanza without a rotation proof.
@(private = "file")
secrets_adopt_command :: proc() {
	need_yes("adopt")
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	if !secrets_store_is_multi(&s) {
		print_error_simple(
			"Nothing to adopt: secrets.json is version 1 (one machine; its key is the master key)",
		)
		wayu_exit(EXIT_DATAERR)
	}
	backend := secrets_backend_active()
	key, name, ok, err := secrets_key_from_own_stanza(&s, backend)
	if !ok {
		exit_with_secret_error(err)
	}
	defer crypto.zero_explicit(&key, size_of(key))
	if wayu.dry_run {
		print_info("[dry-run] Would adopt data key %s (from %s's stanza)", s.key_id, name)
		return
	}
	if saved, serr := keystore_save(backend, key, true); !saved {
		exit_keystore_save_error(backend, serr)
	}
	secrets_cache_invalidate()
	print_success(
		"Adopted data key %s from this machine's stanza (%s); compare it with 'wayu secrets recipient list' on another machine",
		s.key_id,
		name,
	)
}

// Read a passphrase from stdin (hidden on a terminal; asked twice when
// `confirm`). Exits EXIT_USAGE when there is none, EXIT_DATAERR when too
// short or the two differ. Caller wipes it.
@(private = "file")
read_recovery_passphrase :: proc(confirm: bool) -> string {
	p, ok := read_secret_value("", "Recovery passphrase (input hidden): ")
	if !ok {
		print_error_simple("No passphrase (type it, or pipe it on stdin)")
		wayu_exit(EXIT_USAGE)
	}
	if confirm && len(p) < SECRETS_RECOVERY_MIN_PASSPHRASE {
		secrets_wipe(p)
		print_error_simple(
			"The recovery passphrase must be at least %d characters",
			SECRETS_RECOVERY_MIN_PASSPHRASE,
		)
		wayu_exit(EXIT_DATAERR)
	}
	if confirm && bool(posix.isatty(posix.STDIN_FILENO)) {
		again, _ := read_secret_value("", "Repeat it: ")
		same := again == p
		secrets_wipe(again)
		if !same {
			secrets_wipe(p)
			print_error_simple("The passphrases differ: nothing was changed")
			wayu_exit(EXIT_DATAERR)
		}
	}
	return p
}

// `wayu secrets recovery add`: a passphrase stanza (replacing one).
@(private = "file")
secrets_recovery_add :: proc(args: []string) {
	self_name, rest := take_name_flag(args)
	no_extra_args(rest, "wayu secrets recovery add [--name NAME]")
	if len(self_name) == 0 {
		self_name = secrets_default_recipient_name()
	}
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	migrating := !secrets_store_is_multi(&s)
	if wayu.dry_run {
		print_info(
			"[dry-run] Would %s the recovery passphrase%s (passphrase not read)",
			"replace" if len(s.recovery.recipient) > 0 else "set",
			fmt.tprintf(
					", upgrading %s to version 2 with this machine as %s",
					secrets_store_path(),
					self_name,
				) if \
				migrating else \
				"",
		)
		return
	}
	backend := secrets_backend_active()
	pass := read_recovery_passphrase(true)
	defer secrets_wipe(pass)
	key := key_for_header_change(&s)
	defer crypto.zero_explicit(&key, size_of(key))
	snap := secrets_store_snapshot()
	defer secrets_store_snapshot_destroy(&snap)
	id, _ := identity_load_or_create(backend)
	defer crypto.zero_explicit(&id, size_of(id))
	if migrating {
		if !secrets_store_upgrade(
			&s,
			key,
			self_name,
			age_recipient_encode(age_identity_public(id)),
		) {
			exit_with_secret_error("cannot wrap the data key to this machine's identity")
		}
	}
	rec, ok := secrets_recovery_make(key, pass)
	if !ok {
		exit_with_secret_error("cannot derive the recovery key (out of memory)")
	}
	secrets_recovery_destroy(&s.recovery)
	s.recovery = rec
	if secrets_recipient_find_key(&s, age_recipient_encode(age_identity_public(id))) >= 0 {
		secrets_store_save_verified(&s, &snap, key, id)
	} else if ok2, err := secrets_store_save(&s); !ok2 {
		secrets_store_snapshot_restore(&snap)
		exit_with_secret_error(err)
	}
	if migrating {
		upgrade_notice()
	}
	print_success(
		"Recovery passphrase set: 'wayu secrets recovery unlock' (passphrase on stdin) recovers the data key on any machine that has secrets.json. Keep the passphrase offline.",
	)
}

// `wayu secrets recovery rm --yes`: drop the stanza, then rotate.
@(private = "file")
secrets_recovery_rm :: proc(args: []string) {
	no_extra_args(args, "wayu secrets recovery rm --yes")
	need_yes("recovery rm")
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	if !secrets_store_is_multi(&s) || len(s.recovery.recipient) == 0 {
		print_error_simple("No recovery passphrase is set")
		wayu_exit(EXIT_DATAERR)
	}
	if wayu.dry_run {
		print_info(
			"[dry-run] Would remove the recovery passphrase and rotate the data key (%d secret(s))",
			len(s.entries),
		)
		return
	}
	backend := secrets_backend_active()
	old_key, kok, kerr := secrets_key_for_read(&s)
	if !kok {
		exit_with_secret_error(kerr)
	}
	defer crypto.zero_explicit(&old_key, size_of(old_key))
	secrets_recipients_check_or_exit(&s, old_key)
	secrets_recovery_destroy(&s.recovery)
	secrets_rotate_and_commit(&s, backend, old_key)
	print_success("Recovery passphrase removed; new data key %s", s.key_id)
}

// `wayu secrets recovery unlock`: passphrase on stdin → the data key,
// cached as this machine's.
@(private = "file")
secrets_recovery_unlock_command :: proc(args: []string) {
	no_extra_args(args, "wayu secrets recovery unlock")
	secrets_multi_notice()
	config_lock_acquire_or_exit()
	defer config_lock_release()
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	if !secrets_store_is_multi(&s) || len(s.recovery.recipient) == 0 {
		print_error_simple(
			"No recovery passphrase is set in %s (set one with: wayu secrets recovery add)",
			secrets_store_path(),
		)
		wayu_exit(EXIT_DATAERR)
	}
	pass := read_recovery_passphrase(false)
	defer secrets_wipe(pass)
	key, ok, wrong := secrets_recovery_unlock(&s.recovery, pass)
	defer crypto.zero_explicit(&key, size_of(key))
	if !ok {
		if wrong {
			print_error_simple("Wrong recovery passphrase: nothing was changed")
			wayu_exit(EXIT_DATAERR)
		}
		exit_with_secret_error(
			fmt.tprintf(
				"%s: the recovery stanza is broken (a tampered or corrupt file): restore it with 'wayu backup restore entries --yes'",
				secrets_store_path(),
			),
		)
	}
	if got := secrets_key_id(key); got != s.key_id {
		exit_with_secret_error(
			fmt.tprintf(
				"%s: the recovery stanza holds data key %s, not key_id %s (a tampered or corrupt file)",
				secrets_store_path(),
				got,
				s.key_id,
			),
		)
	}
	if wayu.dry_run {
		print_info("[dry-run] Would make data key %s this machine's key", s.key_id)
		return
	}
	backend := secrets_backend_active()
	if saved, serr := keystore_save(backend, key, true); !saved {
		exit_keystore_save_error(backend, serr)
	}
	secrets_cache_invalidate()
	print_success("Unlocked data key %s with the recovery passphrase", s.key_id)
	id, status, _ := keystore_identity_load(backend)
	defer crypto.zero_explicit(&id, size_of(id))
	if status != .OK ||
	   secrets_recipient_find_key(&s, age_recipient_encode(age_identity_public(id))) < 0 {
		fmt.eprintfln(
			"Make this machine a recipient: wayu secrets recipient add \"$(wayu secrets identity)\" --name %s",
			secrets_default_recipient_name(),
		)
	}
}

// ---------------------------------------------------------------------------
// `wayu doctor` (version 2)
// ---------------------------------------------------------------------------

// Doctor rows for a version 2 store (check_secrets adds the version 1 /
// common ones).
check_secrets_multi :: proc(
	results: ^[dynamic]CheckResult,
	s: ^Secrets_Store,
	backend: Secrets_Backend,
	add: proc(results: ^[dynamic]CheckResult, name: string, status: CheckStatus, msg: string),
) {
	add(
		results,
		"secrets recipients",
		.INFO,
		fmt.tprintf(
			"%d recipient(s), data key %s%s (multi-machine, experimental)",
			len(s.recipients),
			s.key_id,
			", recovery passphrase set" if len(s.recovery.recipient) > 0 else "",
		),
	)
	key, name, ok, err := secrets_key_from_own_stanza(s, backend)
	defer crypto.zero_explicit(&key, size_of(key))
	if !ok {
		add(results, "secrets identity", .ERROR, err)
		return
	}
	add(results, "secrets identity", .OK, fmt.tprintf("this machine is recipient %s", name))
	if bad := secrets_recipients_check(s, key); len(bad) > 0 {
		add(
			results,
			"secrets recipients",
			.ERROR,
			fmt.tprintf(
				"the stanza of %s was not written by wayu with data key %s (tampered?): drop it with %s",
				bad,
				s.key_id,
				"wayu secrets recovery rm --yes" if \
					bad == "recovery" else \
					fmt.tprintf("wayu secrets recipient rm %s --yes", bad),
			),
		)
	}
	cached, status, msg := secrets_key_load(backend)
	defer crypto.zero_explicit(&cached, size_of(cached))
	switch {
	case status == .OK && secrets_key_id(cached) == s.key_id:
	case status == .MISSING:
		add(
			results,
			"secrets backend",
			.ERROR,
			fmt.tprintf(
				"data key %s is not cached on this machine yet: compare it with 'wayu secrets recipient list' on another machine, then run: wayu secrets adopt --yes",
				s.key_id,
			),
		)
	case status == .OK && secrets_rotation_chain_verify(s.rotations[:], cached, key):
		add(
			results,
			"secrets backend",
			.WARNING,
			fmt.tprintf(
				"data key rotated %s -> %s (proof verified): the next secrets command adopts it",
				secrets_key_id(cached),
				s.key_id,
			),
		)
	case status == .OK:
		add(
			results,
			"secrets backend",
			.ERROR,
			fmt.tprintf(
				"data key %s is not proven by a rotation from the cached key %s: compare it with 'wayu secrets recipient list' on another machine, then run: wayu secrets adopt --yes",
				s.key_id,
				secrets_key_id(cached),
			),
		)
	case:
		add(results, "secrets backend", .ERROR, msg)
	}
	bad := make([dynamic]string, context.temp_allocator)
	for e in s.entries {
		v, dok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			append(&bad, e.name)
			continue
		}
		secrets_wipe(v)
	}
	if len(bad) > 0 {
		add(
			results,
			"secrets values",
			.ERROR,
			fmt.tprintf(
				"%d secret(s) do not decrypt with data key %s (a concurrent rekey on another machine, or tampering): %s; re-add them with 'wayu const add NAME --secret'",
				len(bad),
				s.key_id,
				strings.join(bad[:], ", ", context.temp_allocator),
			),
		)
	} else {
		add(
			results,
			"secrets values",
			.OK,
			fmt.tprintf("every secret decrypts with data key %s", s.key_id),
		)
	}
}

// Doctor rows common to both versions: key files inside a git work tree
// and not ignored, sync-conflict copies next to the store.
check_secrets_files :: proc(
	results: ^[dynamic]CheckResult,
	add: proc(results: ^[dynamic]CheckResult, name: string, status: CheckStatus, msg: string),
) {
	for path in ([]string{secret_key_file_path(), identity_key_file_path()}) {
		if !os.exists(path) {
			continue
		}
		dir, file := os.split_path(path)
		res := run_command_timeout([]string{"git", "-C", dir, "check-ignore", "-q", file}, 10_000)
		defer command_result_destroy(&res)
		// 0: ignored; 1: in a work tree and not ignored; else no repo / no git.
		if !res.ok && res.exit_code == 1 {
			add(
				results,
				"secrets key files",
				.WARNING,
				fmt.tprintf(
					"%s is inside a git work tree and not ignored: add it to .gitignore so it is never committed",
					path,
				),
			)
		}
	}
	conflicts := make([dynamic]string, context.temp_allocator)
	if entries, err := os.read_all_directory_by_path(wayu.data, context.temp_allocator);
	   err == nil {
		for fi in entries {
			n := fi.name
			if n == SECRETS_STORE_FILE || !strings.has_prefix(n, "secrets") {
				continue
			}
			if strings.has_suffix(n, ".json") &&
			   (strings.contains(n, "conflict") || strings.has_prefix(n, "secrets ")) {
				append(&conflicts, n)
			}
		}
	}
	if len(conflicts) > 0 {
		slice.sort(conflicts[:])
		add(
			results,
			"secrets sync",
			.WARNING,
			fmt.tprintf(
				"sync conflict copies next to %s: %s; merge any value they hold that secrets.json lacks (wayu const add NAME --secret), then delete them",
				SECRETS_STORE_FILE,
				strings.join(conflicts[:], ", ", context.temp_allocator),
			),
		)
	}
}

// ---------------------------------------------------------------------------
// `wayu backup restore` over a version 2 store
// ---------------------------------------------------------------------------

// The secrets.json text to restore from a backup's copy (`copy`; empty: no
// secrets.json then). While the live store is version 2, the result keeps
// its header (key_id, recipients, rotations, recovery) with the copy's
// values, which must open with the current data key: a version 1 copy (or
// one from before a recipient change) is re-wrapped to the current
// recipients instead of silently dropping them. Otherwise `copy` is
// returned as is. err (temp-allocated) refuses the restore. The result is
// heap-allocated when `rewrapped`.
secrets_restore_merge :: proc(copy: []byte) -> (text: []byte, rewrapped: bool, err: string) {
	data, rerr := os.read_entire_file_from_path(secrets_store_path(), context.allocator)
	if rerr != nil {
		return copy, false, ""
	}
	live, perr := secrets_store_parse(string(data))
	delete(data)
	defer secrets_store_destroy(&live)
	if len(perr) > 0 || !secrets_store_is_multi(&live) {
		return copy, false, ""
	}
	old: Secrets_Store
	defer secrets_store_destroy(&old)
	if len(copy) > 0 {
		cerr: string
		old, cerr = secrets_store_parse(string(copy))
		if len(cerr) > 0 {
			return nil, false, cerr
		}
	}
	if len(old.entries) > 0 {
		key, kok, kerr := secrets_key_for_read(&live)
		if !kok {
			return nil, false, kerr
		}
		defer crypto.zero_explicit(&key, size_of(key))
		for e in old.entries {
			v, dok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
			if !dok {
				return nil, false, fmt.tprintf(
					"the secrets.json copy in this backup does not decrypt with the current data key %s (%s; it predates a key rotation): restoring it would make the secrets unreadable, so nothing was restored",
					live.key_id,
					e.name,
				)
			}
			secrets_wipe(v)
		}
	}
	// Live header, the copy's values.
	for e in live.entries {
		delete(e.name)
		delete(e.blob)
	}
	clear(&live.entries)
	for e in old.entries {
		append(
			&live.entries,
			Secret_Entry {
				name = strings.clone(e.name),
				blob = strings.clone(e.blob),
				run_only = e.run_only,
			},
		)
	}
	out := secrets_store_format(&live)
	return transmute([]byte)out, true, ""
}
