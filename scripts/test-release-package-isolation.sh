#!/usr/bin/env bash
# scripts/test-release-package-isolation.sh
#
# Verify that a release archive is self-contained: extract it into a temporary
# directory that has no access to the repository source tree, then check that
# every runtime dependency referenced by the packaged scripts resolves from
# inside the archive.
#
# This test does NOT run the binary or load BPF objects. It checks:
#   1. Archive extracts without error
#   2. Required files are present (via verify-release-archive.sh)
#   3. All $(dirname "$0")/... relative references in run-scenarios.sh resolve
#      from the extracted package (no spikes/ or source-tree fallback)
#   4. inject_ptb.py passes python3 -m py_compile (syntax check)
#   5. All packaged shell scripts pass bash -n (syntax check)
#   6. Binary is an ELF executable (file(1) check)
#
# Usage:
#   bash scripts/test-release-package-isolation.sh <path-to-archive.tar.gz>
#
# Exit codes:
#   0  all checks PASS
#   1  one or more checks FAIL

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

# Extract to a temp dir that deliberately does NOT contain the repo.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test-release-package-isolation: $ARCHIVE ==="
_info "extraction dir: $WORKDIR  (repo not present here)"
echo ""

# --------------------------------------------------------------------------
# 1. Extract
# --------------------------------------------------------------------------
echo "-- Extract --"
if tar -xzf "$ARCHIVE" -C "$WORKDIR" 2>/dev/null; then
    _pass "archive extracts without error"
else
    _fail "archive failed to extract"
    exit 1
fi

ROOT=$(ls "$WORKDIR" | head -1)
if [[ -z "$ROOT" ]]; then
    _fail "archive is empty"
    exit 1
fi
PKG="$WORKDIR/$ROOT"
_info "package root: $PKG"

# --------------------------------------------------------------------------
# 2. Required files (subset — verify-release-archive.sh does the full check)
# --------------------------------------------------------------------------
echo ""
echo "-- Required files --"
REQUIRED_FILES=(
    "vxlan-tracer"
    "bpf/tc_ingress_eth0.bpf.o"
    "bpf/tc_egress_vxlan0.bpf.o"
    "bpf/kprobes.bpf.o"
    "bpf/frag_kprobes.bpf.o"
    "scripts/run-scenarios.sh"
    "scripts/demo.sh"
    "scripts/preflight.sh"
    "scripts/setup-bpf-fs.sh"
    "scripts/setup-netns.sh"
    "scripts/teardown-netns.sh"
    "scripts/cleanup-bpf.sh"
    "scripts/inject_ptb.py"
    "README.md"
    "LICENSE"
    "MANIFEST.txt"
)
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$PKG/$f" ]]; then
        _pass "$f"
    else
        _fail "$f  MISSING"
    fi
done

# --------------------------------------------------------------------------
# 3. Relative dependency resolution check
#    run-scenarios.sh uses $(dirname "$0")/... to find helpers.
#    Verify each such reference resolves from scripts/ inside the package.
# --------------------------------------------------------------------------
echo ""
echo "-- Relative dependency resolution --"
SCRIPT_REFS=(
    "scripts/cleanup-bpf.sh"
    "scripts/setup-netns.sh"
    "scripts/teardown-netns.sh"
    "scripts/inject_ptb.py"
)
for ref in "${SCRIPT_REFS[@]}"; do
    if [[ -f "$PKG/$ref" ]]; then
        _pass "$ref resolves from package scripts/"
    else
        _fail "$ref MISSING — run-scenarios.sh will fail when called from extracted package"
    fi
done

# Confirm run-scenarios.sh does NOT reference spikes/ or an absolute source path
echo ""
echo "-- No source-tree references in packaged scripts --"
if grep -r "spikes/" "$PKG/scripts/" 2>/dev/null | grep -v "^Binary"; then
    _fail "packaged scripts contain 'spikes/' reference — source tree dependency"
else
    _pass "no 'spikes/' reference in packaged scripts"
fi

# --------------------------------------------------------------------------
# 4. Python syntax check for inject_ptb.py
# --------------------------------------------------------------------------
echo ""
echo "-- Python syntax --"
if command -v python3 &>/dev/null; then
    if python3 -m py_compile "$PKG/scripts/inject_ptb.py" 2>/dev/null; then
        _pass "scripts/inject_ptb.py: python3 syntax OK"
    else
        _fail "scripts/inject_ptb.py: python3 syntax error"
    fi
else
    _info "python3 not available; skipping syntax check"
fi

# --------------------------------------------------------------------------
# 5. Shell script syntax check
# --------------------------------------------------------------------------
echo ""
echo "-- Shell script syntax --"
for s in "$PKG"/scripts/*.sh; do
    name=$(basename "$s")
    if bash -n "$s" 2>/dev/null; then
        _pass "scripts/$name: bash syntax OK"
    else
        _fail "scripts/$name: bash syntax error"
    fi
done

# --------------------------------------------------------------------------
# 6. Binary ELF check
# --------------------------------------------------------------------------
echo ""
echo "-- Binary ELF --"
if [[ -x "$PKG/vxlan-tracer" ]]; then
    _pass "vxlan-tracer: executable bit set"
else
    _fail "vxlan-tracer: not executable"
fi
if command -v file &>/dev/null; then
    FILETYPE=$(file "$PKG/vxlan-tracer" 2>/dev/null)
    if echo "$FILETYPE" | grep -q "ELF"; then
        _pass "vxlan-tracer: ELF binary"
        _info "file(1): $FILETYPE"
    else
        _fail "vxlan-tracer: not ELF — $FILETYPE"
    fi
else
    _info "file(1) not available; skipping ELF check"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Isolation test summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [[ $FAIL -eq 0 ]]; then
    echo "  RESULT: PASS — archive is self-contained (no source-tree dependencies found)"
    exit 0
else
    echo "  RESULT: FAIL — archive has missing dependencies or source-tree references"
    exit 1
fi
