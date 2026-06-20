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
echo "-- Binary version check --"
if [[ -f "$PKG/vxlan-tracer" && -x "$PKG/vxlan-tracer" ]]; then
    # Attempt to run --version only when the binary arch matches the host.
    # ELF machine field: 0x3e = x86-64, 0xb7 = AArch64 (ARM64).
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
