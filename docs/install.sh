#!/bin/sh
# wayu installer: https://wayu.dvrd.io/install.sh
#
#   curl -fsSL https://wayu.dvrd.io/install.sh | sh
#
# Downloads the prebuilt wayu for this OS/CPU from the GitHub release,
# verifies its SHA-256 (and, when the GitHub CLI is installed and logged in,
# its build provenance attestation), and installs it to ~/.local/bin.
# Nothing else is downloaded, nothing is sent anywhere, nothing is run as root.
#
# Environment:
#   WAYU_VERSION      release to install, e.g. v7.0.0 (default: the latest)
#   WAYU_INSTALL_DIR  install directory (default: $HOME/.local/bin)
#   WAYU_FORCE=1      install even though Homebrew manages a wayu
#
# Every failure stops the install and says how to fix it; an existing wayu
# is replaced only after the new one is downloaded, verified and runs.

set -eu

REPO="dvrd/wayu"
SOURCE_HINT="build from source instead: https://github.com/$REPO#from-source"

say() {
	printf '%s\n' "$*"
}

die() {
	printf 'wayu install: error: %s\n' "$1" >&2
	shift
	for line in "$@"; do
		printf '  %s\n' "$line" >&2
	done
	exit 1
}

# The release asset for this machine: wayu-<os>-<arch>.
detect_platform() {
	os=$(uname -s)
	arch=$(uname -m)
	case "$os" in
		Darwin) os=macos ;;
		Linux) os=linux ;;
		*) die "no prebuilt wayu for $os ($arch)." "wayu has binaries for macOS and Linux only; $SOURCE_HINT" ;;
	esac
	case "$arch" in
		arm64 | aarch64) arch=arm64 ;;
		x86_64 | amd64) arch=amd64 ;;
		*) die "no prebuilt wayu for $os on $arch." "Binaries exist for arm64 and x86_64; $SOURCE_HINT" ;;
	esac

	if [ "$os" = macos ]; then
		# A shell under Rosetta reports x86_64 on Apple silicon: install the
		# native binary.
		if [ "$arch" = amd64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
			arch=arm64
		fi
		macos_version=$(sw_vers -productVersion 2>/dev/null || echo 0)
		if [ "${macos_version%%.*}" -lt 15 ] 2>/dev/null; then
			die "the prebuilt wayu needs macOS 15 or later (this is macOS $macos_version)." \
				"Upgrade macOS, or $SOURCE_HINT"
		fi
	else
		# The Linux binaries link glibc.
		if ldd --version 2>&1 | grep -qi musl; then
			die "the prebuilt wayu needs glibc; this system uses musl." "$SOURCE_HINT"
		fi
	fi
	asset="wayu-$os-$arch"
}

# vX.Y.Z from WAYU_VERSION, or the latest release (the tag GitHub's
# /releases/latest redirects to: no API call, no API rate limit).
resolve_version() {
	version="${WAYU_VERSION:-}"
	if [ -z "$version" ]; then
		latest_url=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o /dev/null \
			-w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
			die "cannot reach GitHub to find the latest wayu release." \
				"Check your network, or pin one: WAYU_VERSION=vX.Y.Z (see https://github.com/$REPO/releases)"
		version="${latest_url##*/}"
	fi
	case "$version" in
		v*) ;;
		*) version="v$version" ;;
	esac
	case "$version" in
		v*[!0-9.]* | v*..* | v.* | *. | v)
			die "'$version' is not a release version." "Use WAYU_VERSION=vX.Y.Z (see https://github.com/$REPO/releases)"
			;;
	esac
	dots=$(printf '%s' "$version" | tr -cd . | wc -c | tr -d ' ')
	[ "$dots" = 2 ] ||
		die "'$version' is not a release version." "Use WAYU_VERSION=vX.Y.Z (see https://github.com/$REPO/releases)"
}

download() {
	# $1 url, $2 output file
	curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "neither sha256sum nor shasum is installed; cannot verify the download." \
			"Install coreutils (sha256sum) or perl (shasum), then run the installer again."
	fi
}

# A wayu that Homebrew manages: <prefix>/bin/wayu linking into Cellar/wayu/
# (the same check as ./build_it install).
homebrew_wayu() {
	for prefix in "${HOMEBREW_PREFIX:-}" /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
		[ -n "$prefix" ] || continue
		link="$prefix/bin/wayu"
		[ -L "$link" ] || continue
		case "$(readlink "$link" 2>/dev/null)" in
			*Cellar/wayu/*)
				printf '%s\n' "$link"
				return 0
				;;
		esac
	done
	return 0
}

main() {
	for tool in curl tar uname mktemp; do
		command -v "$tool" >/dev/null 2>&1 ||
			die "'$tool' is required but not installed." "Install it with your package manager, then run the installer again."
	done
	[ -n "${HOME:-}" ] || [ -n "${WAYU_INSTALL_DIR:-}" ] ||
		die "HOME is not set; cannot choose an install directory." "Set WAYU_INSTALL_DIR=/path/to/bin."
	install_dir="${WAYU_INSTALL_DIR:-$HOME/.local/bin}"
	install_dir="${install_dir%/}"
	target="$install_dir/wayu"

	brew_link=$(homebrew_wayu)
	if [ -n "$brew_link" ] && [ "${WAYU_FORCE:-}" != 1 ]; then
		die "wayu is installed by Homebrew ($brew_link)." \
			"Two copies on PATH mean the shell runs one and you upgrade the other. Either:" \
			"  brew upgrade wayu      # keep using Homebrew" \
			"  brew uninstall wayu    # then run this again to switch to this installer" \
			"  curl -fsSL https://wayu.dvrd.io/install.sh | WAYU_FORCE=1 sh" \
			"      # install to $install_dir anyway"
	fi

	detect_platform
	resolve_version

	tmp=$(mktemp -d 2>/dev/null || mktemp -d -t wayu-install) ||
		die "cannot create a temporary directory." "Set TMPDIR to a writable directory."
	trap 'rm -rf "$tmp"' EXIT
	trap 'rm -rf "$tmp"; exit 130' INT TERM

	base="https://github.com/$REPO/releases/download/$version"
	say "Downloading wayu $version ($asset)..."
	download "$base/$asset.sha256" "$tmp/$asset.sha256" ||
		die "release $version has no $asset.sha256 (or GitHub is unreachable)." \
			"Check the version at https://github.com/$REPO/releases; releases before the" \
			"multi-platform builds ship macOS arm64 and Linux x86_64 only. Or $SOURCE_HINT"
	download "$base/$asset.tar.gz" "$tmp/$asset.tar.gz" ||
		die "cannot download $base/$asset.tar.gz." "Check your network and run the installer again."

	expected=$(awk 'NR == 1 {print $1}' "$tmp/$asset.sha256")
	case "$expected" in
		*[!0-9a-f]*) expected= ;;
	esac
	[ "${#expected}" = 64 ] ||
		die "$asset.sha256 holds no SHA-256." "Report it at https://github.com/$REPO/issues; do not install this release by hand."
	actual=$(sha256_of "$tmp/$asset.tar.gz")
	[ "$actual" = "$expected" ] ||
		die "SHA-256 mismatch for $asset.tar.gz: expected $expected, got $actual." \
			"The download is corrupt or was tampered with; nothing was installed." \
			"Run the installer again; if it keeps failing, report it at https://github.com/$REPO/issues."
	say "Checksum OK ($actual)."

	if command -v gh >/dev/null 2>&1; then
		# --active: an inactive account with a stale token fails plain
		# `gh auth status` though gh can verify (older gh lacks the flag).
		if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || gh auth status --active >/dev/null 2>&1 ||
			gh auth status >/dev/null 2>&1; then
			gh attestation verify "$tmp/$asset.tar.gz" --repo "$REPO" >/dev/null ||
				die "the build provenance attestation of $asset.tar.gz did not verify." \
					"Nothing was installed. Releases up to v5.0.0 have no attestation (pick a newer" \
					"WAYU_VERSION); otherwise report it at https://github.com/$REPO/issues."
			say "Attestation OK (built by $REPO's release workflow)."
		else
			say "Note: gh is not logged in; skipped the attestation check (gh auth login to enable it)."
		fi
	else
		say "Note: gh (GitHub CLI) is not installed; skipped the attestation check."
	fi

	[ "$(tar -tzf "$tmp/$asset.tar.gz")" = wayu ] ||
		die "$asset.tar.gz must hold exactly one file, wayu." "Report it at https://github.com/$REPO/issues."
	mkdir "$tmp/unpack"
	tar -xzf "$tmp/$asset.tar.gz" -C "$tmp/unpack" wayu
	chmod 0755 "$tmp/unpack/wayu"
	reported=$("$tmp/unpack/wayu" --version 2>/dev/null | head -n 1) || reported=
	[ "$reported" = "wayu $version" ] ||
		die "the downloaded wayu does not run here (it printed '${reported:-nothing}')." \
			"Nothing was installed. $SOURCE_HINT"

	mkdir -p "$install_dir" ||
		die "cannot create $install_dir." "Set WAYU_INSTALL_DIR to a directory you can write."
	previous=
	if [ -x "$target" ]; then
		previous=$("$target" --version 2>/dev/null | head -n 1) || previous=
	fi
	# Copy next to the target, then rename over it: atomic, and a running
	# wayu keeps its old inode (macOS kills a signed binary rewritten in place).
	staged="$install_dir/.wayu.install.$$"
	if ! cp "$tmp/unpack/wayu" "$staged" 2>/dev/null || ! chmod 0755 "$staged" ||
		! mv -f "$staged" "$target"; then
		rm -f "$staged"
		die "cannot write $target." "Set WAYU_INSTALL_DIR to a directory you can write."
	fi

	if [ -n "$previous" ] && [ "$previous" != "wayu $version" ]; then
		say "Upgraded $target: ${previous#wayu } -> $version"
	else
		say "Installed wayu $version to $target"
	fi

	say ""
	say "Next steps:"
	on_path=
	case ":${PATH:-}:" in
		*":$install_dir:"*) on_path=1 ;;
	esac
	if [ -z "$on_path" ]; then
		say "  $install_dir is not on your PATH. Add it, e.g. in ~/.zshrc or ~/.bashrc:"
		say "    export PATH=\"$install_dir:\$PATH\""
		say "  (fish: fish_add_path $install_dir)"
	else
		found=$(command -v wayu 2>/dev/null || true)
		if [ -n "$found" ] && [ "$found" != "$target" ]; then
			say "  'wayu' on your PATH is $found, which shadows $target;"
			say "  remove it or put $install_dir earlier in PATH."
		fi
	fi
	say "  Run: wayu init"
	say "  Docs: https://wayu.dvrd.io/docs/quickstart.html"
}

main "$@"
