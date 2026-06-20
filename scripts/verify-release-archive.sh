#!/usr/bin/env bash
# scripts/verify-release-archive.sh
#
# Verify the contents of a vxlan-tracer release archive produced by make package.
# Checks that all required files are present and that the binary is an ELF file.
#
# Usage:
#   bash scripts/verify-release-archive.sh <path-to-archive.tar.gz>
#   make verify-release-archive ARCHIVE=dist/release/vxlan-tracer-linux-amd64.tar.gz
#
# Exit codes:
#   0  all checks PASS — archive is complete
#   1  one or more checks FAIL — archive is incomplete or corrupt

set -uo pipefail

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    echo "Usage: $0 <path-to-archive.tar.gz>" >&2
    echo "  e.g.: $0 dist/release/vxlan-tracer-linux-amd64.tar.gz" >&2
    exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
    echo "ERROR: archive not found: $ARCHIVE" >&2
    exit 1
fi

PASS=0
FAIL=0
_pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
_info() { echo "  INFO  $*"; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== verify-release-archive: $ARCHIVE ==="
_info "size: $(wc -c < "$ARCHIVE") bytes"
echo ""

# --------------------------------------------------------------------------
# Extract
# --------------------------------------------------------------------------
if ! tar -xzf "$ARCHIVE" -C "$TMPDIR" 2>/dev/null; then
    echo "ERROR: failed to extract archive: $ARCHIVE" >&2
    exit 1
fi
ROOT=$(ls "$TMPDIR" 2>/dev/null | head -1)
if [[ -z "$ROOT" ]]; then
    _fail "archive is empty or failed to extract"
    exit 1
fi
_info "root directory: $ROOT"
PKG="$TMPDIR/$ROOT"

echo ""
echo "-- Binary --"
if [[ -f "$PKG/vxlan-tracer" ]]; then
    if [[ -x "$PKG/vxlan-tracer" ]]; then
        _pass "vxlan-tracer: present and executable"
    else
        _fail "vxlan-tracer: present but NOT executable (permissions wrong)"
    fi
    if command -v file &>/dev/null; then
        FILETYPE=$(file "$PKG/vxlan-tracer" 2>/dev/null)
        if echo "$FILETYPE" | grep -q "ELF"; then
            _pass "vxlan-tracer: ELF binary ($FILETYPE)"
        else
            _fail "vxlan-tracer: not an ELF binary: $FILETYPE"
        fi
    else
        _info "file(1) not available; skipping ELF check"
    fi
else
    _fail "vxlan-tracer: MISSING"
fi

echo ""
echo "-- Required BPF objects --"
for obj in tc_ingress_eth0.bpf.o tc_egress_vxlan0.bpf.o kprobes.bpf.o frag_kprobes.bpf.o; do
    if [[ -f "$PKG/bpf/$obj" ]]; then
        SZ=$(wc -c < "$PKG/bpf/$obj" 2>/dev/null || echo "?")
        _pass "bpf/$obj  (${SZ} bytes)"
    else
        _fail "bpf/$obj  MISSING — package was built without BPF objects"
    fi
done

echo ""
echo "-- Required scripts --"
for s in preflight.sh run-scenarios.sh demo.sh setup-bpf-fs.sh \
          setup-netns.sh teardown-netns.sh cleanup-bpf.sh inject_ptb.py; do
    if [[ -f "$PKG/scripts/$s" ]]; then
        _pass "scripts/$s"
    else
        _fail "scripts/$s  MISSING"
    fi
done

echo ""
echo "-- Documentation --"
for f in README.md LICENSE MANIFEST.txt; do
    if [[ -f "$PKG/$f" ]]; then
        _pass "$f"
    else
        _fail "$f  MISSING"
    fi
done

echo ""
echo "-- MANIFEST.txt contents --"
if [[ -f "$PKG/MANIFEST.txt" ]]; then
    sed 's/^/    /' "$PKG/MANIFEST.txt"
fi

echo ""
echo "-- Manifest arch vs archive name --"
_ARCHIVE_BASENAME=$(basename "$ARCHIVE")
_MANIFEST_ARCH=""
if [[ -f "$PKG/MANIFEST.txt" ]]; then
    _MANIFEST_ARCH=$(grep "^Architecture:" "$PKG/MANIFEST.txt" 2>/dev/null | awk '{print $2}')
fi
if [[ -n "$_MANIFEST_ARCH" ]]; then
    if echo "$_ARCHIVE_BASENAME" | grep -q "$_MANIFEST_ARCH"; then
        _pass "MANIFEST.txt Architecture: '$_MANIFEST_ARCH' matches archive name '$_ARCHIVE_BASENAME'"
    else
        _fail "MANIFEST.txt Architecture: '$_MANIFEST_ARCH' does NOT match archive name '$_ARCHIVE_BASENAME'"
    fi
else
    _info "MANIFEST.txt missing or has no Architecture: field — skipping arch match"
fi

echo ""
echo "-- BPF target define (MANIFEST.txt) --"
_MANIFEST_BPF_TARGET=""
if [[ -f "$PKG/MANIFEST.txt" ]]; then
    _MANIFEST_BPF_TARGET=$(grep "^BPF target:" "$PKG/MANIFEST.txt" 2>/dev/null | sed 's/BPF target:[[:space:]]*//')
fi
if [[ -n "$_MANIFEST_BPF_TARGET" ]]; then
    _EXPECTED_BPF=""
    if echo "$_ARCHIVE_BASENAME" | grep -q "amd64"; then
        _EXPECTED_BPF="__TARGET_ARCH_x86"
    elif echo "$_ARCHIVE_BASENAME" | grep -q "arm64"; then
        _EXPECTED_BPF="__TARGET_ARCH_arm64"
    fi
    if [[ -n "$_EXPECTED_BPF" ]]; then
        if [[ "$_MANIFEST_BPF_TARGET" == "$_EXPECTED_BPF" ]]; then
            _pass "BPF target '$_MANIFEST_BPF_TARGET' matches expected for $_ARCHIVE_BASENAME"
        else
            _fail "BPF target '$_MANIFEST_BPF_TARGET' expected '$_EXPECTED_BPF' for $_ARCHIVE_BASENAME"
        fi
    else
        _info "cannot infer expected BPF target from archive name '$_ARCHIVE_BASENAME'"
    fi
else
    _info "MANIFEST.txt missing BPF target: field — skipping BPF target check"
fi

echo ""
echo "-- Script executability --"
for s in "$PKG"/scripts/*.sh; do
    name=$(basename "$s")
    if [[ -x "$s" ]]; then
        _pass "scripts/$name: executable"
    else
        _info "scripts/$name: not executable (called via 'bash scripts/...' so not required)"
    fi
done

echo ""
echo "-- Python syntax check --"
if command -v python3 &>/dev/null && [[ -f "$PKG/scripts/inject_ptb.py" ]]; then
    if python3 -m py_compile "$PKG/scripts/inject_ptb.py" 2>/dev/null; then
        _pass "scripts/inject_ptb.py: python3 syntax OK"
    else
        _fail "scripts/inject_ptb.py: python3 syntax error"
    fi
else
    _info "python3 unavailable or inject_ptb.py missing — skipping syntax check"
fi

echo ""
echo "-- SHA-256 checksum (if companion .sha256 file present) --"
_SHA256FILE="${ARCHIVE%.tar.gz}.sha256"
# Also check checksums-<arch>.sha256 in the same directory
_ARCHDIR=$(dirname "$ARCHIVE")
_ARCHNAME=$(basename "$ARCHIVE")
_CHECKSUMFILE="$_ARCHDIR/checksums-$(echo "$_ARCHNAME" | grep -oE 'amd64|arm64').sha256"
if [[ -f "$_SHA256FILE" ]]; then
    if (cd "$(dirname "$ARCHIVE")" && sha256sum --check "$(basename "$_SHA256FILE")" 2>/dev/null | grep -q "OK"); then
        _pass "SHA-256 checksum verified: $(basename "$_SHA256FILE")"
    else
        _fail "SHA-256 checksum mismatch: $(basename "$_SHA256FILE")"
    fi
elif [[ -f "$_CHECKSUMFILE" ]]; then
    if (cd "$_ARCHDIR" && sha256sum --check "$(basename "$_CHECKSUMFILE")" 2>/dev/null | grep -q "OK"); then
        _pass "SHA-256 checksum verified: $(basename "$_CHECKSUMFILE")"
    else
        _fail "SHA-256 checksum mismatch or file not matching: $(basename "$_CHECKSUMFILE")"
    fi
else
    _info "no companion .sha256 file found alongside archive — skipping checksum verification"
fi

echo ""
echo "-- Binary version check --"
if [[ -f "$PKG/vxlan-tracer" && -x "$PKG/vxlan-tracer" ]]; then
    # Attempt to run --version only when the binary arch matches the host.
    _HOST_MACHINE=$(uname -m 2>/dev/null || echo unknown)
    _ELF_OK=0
    if command -v file &>/dev/null; then
        FILETYPE=$(file "$PKG/vxlan-tracer" 2>/dev/null)
        if (echo "$FILETYPE" | grep -qi "x86-64") && [ "$_HOST_MACHINE" = "x86_64" ]; then
            _ELF_OK=1
        elif (echo "$FILETYPE" | grep -qi "aarch64\|arm64\|ARM aarch64") && [ "$_HOST_MACHINE" = "aarch64" ]; then
            _ELF_OK=1
        fi
    fi
    if [[ $_ELF_OK -eq 1 ]]; then
        _VER=$("$PKG/vxlan-tracer" --version 2>&1 || echo "FAILED")
        if echo "$_VER" | grep -q "vxlan-tracer"; then
            _pass "binary --version: $_VER"
        else
            _fail "binary --version returned unexpected output: $_VER"
        fi
    else
        _info "skipping binary execution (host arch=$_HOST_MACHINE does not match binary arch or file(1) unavailable)"
    fi
fi

echo ""
echo "=== Verification summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo "  RESULT: PASS — archive is complete and valid"
    exit 0
else
    echo "  RESULT: FAIL — archive is incomplete or invalid"
    exit 1
fi
