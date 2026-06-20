#!/usr/bin/env bash
# scripts/test-stale-bpf-object.sh
#
# Integration test: verify the loader fails with a clear error when given a
# TC ingress BPF object compiled without the vxlan_config map.
#
# This proves the stale-object guard works end-to-end, not just via the unit
# test (TestWriteVXLANPortToMapsMissing) that passes an empty map collection.
# The integration test actually loads an ELF file through the full Go loader
# path: ELF parse → BPF verifier → map lookup → expected error.
#
# Requirements: Linux, root, clang, libbpf-dev
#
# Environment variables:
#   BINARY       path to compiled vxlan-tracer binary (default: dist/vxlan-tracer)
#   FIXTURE_SRC  path to stale BPF fixture source (default: tests/fixtures/tc_ingress_missing_config.bpf.c)
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed
#   77 test skipped (environment cannot support it: not Linux, not root, no clang)

set -uo pipefail

BINARY="${BINARY:-dist/vxlan-tracer}"
FIXTURE_SRC="${FIXTURE_SRC:-tests/fixtures/tc_ingress_missing_config.bpf.c}"
STALE_BPF_DIR="/tmp/stale-bpf-test-$$"
# Network namespace and veth names for the minimal test lab.
# All <= 14 chars (Linux ifname limit is 15, IFNAMSIZ-1).
TNETNS="sl-test-ns"
VETH_A="sl-test-a"
VETH_B="sl-test-b"

PASS=0
FAIL=0

_pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
_info() { echo "  INFO  $*"; }

cleanup() {
    ip netns del "$TNETNS" 2>/dev/null || true
    ip link del "$VETH_A"  2>/dev/null || true
    rm -rf "$STALE_BPF_DIR"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Preflight: skip gracefully if environment cannot support this test
# --------------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP (77): test requires Linux" >&2
    exit 77
fi
if [[ $EUID -ne 0 ]]; then
    echo "SKIP (77): test requires root" >&2
    exit 77
fi
if ! command -v clang &>/dev/null; then
    echo "SKIP (77): clang not available — install clang + libbpf-dev" >&2
    exit 77
fi
if [[ ! -f "$BINARY" ]]; then
    echo "SKIP (77): binary not found at $BINARY — run 'make build' first" >&2
    exit 77
fi
if [[ ! -f "$FIXTURE_SRC" ]]; then
    echo "SKIP (77): fixture not found at $FIXTURE_SRC" >&2
    exit 77
fi

echo ""
echo "=== Stale BPF object integration test ==="
echo "binary:  $BINARY"
echo "fixture: $FIXTURE_SRC"
echo ""

# --------------------------------------------------------------------------
# Step 1: Compile the stale fixture
# --------------------------------------------------------------------------
echo "[1] Compiling stale fixture..."
mkdir -p "$STALE_BPF_DIR"

_ARCH=$(uname -m)
case "$_ARCH" in
    aarch64) _ARCH_INC="-I/usr/include/aarch64-linux-gnu" ;;
    x86_64)  _ARCH_INC="-I/usr/include/x86_64-linux-gnu -D__x86_64__" ;;
    *)        _ARCH_INC="" ;;
esac

# shellcheck disable=SC2086
if clang -O2 -g -target bpf \
      -I/usr/include \
      $_ARCH_INC \
      -Wall -Wno-unused-value -Wno-pointer-sign \
      -c "$FIXTURE_SRC" \
      -o "$STALE_BPF_DIR/tc_ingress_eth0.bpf.o" 2>&1; then
    _pass "stale fixture compiled: $STALE_BPF_DIR/tc_ingress_eth0.bpf.o"
else
    _fail "stale fixture compilation failed — check clang and libbpf-dev"
    exit 1
fi

# --------------------------------------------------------------------------
# Step 2: Create a minimal network namespace + veth pair for the binary
# --------------------------------------------------------------------------
# The loader's Attach() resolves interface names via netlink before loading
# BPF objects, so we need real interfaces even though we expect early failure.
echo "[2] Creating test network namespace and veth pair..."

if ! ip netns add "$TNETNS" 2>&1; then
    _fail "ip netns add failed — cannot create test namespace; skipping"
    exit 77
fi
if ! ip link add "$VETH_A" type veth peer name "$VETH_B" 2>&1; then
    _fail "ip link add veth failed — runner may not support veth creation; skipping"
    exit 77
fi
ip link set "$VETH_A" netns "$TNETNS"
ip link set "$VETH_B" netns "$TNETNS"
ip netns exec "$TNETNS" ip link set "$VETH_A" up
ip netns exec "$TNETNS" ip link set "$VETH_B" up
_pass "test namespace and veth pair ready ($VETH_A ↔ $VETH_B in $TNETNS)"

# --------------------------------------------------------------------------
# Step 3: Run the binary with the stale BPF dir; capture stderr + exit code
# --------------------------------------------------------------------------
echo "[3] Running binary with stale TC ingress object..."
_STDERR_TMP="/tmp/stale-test-stderr-$$"
set +e
nsenter --net="/var/run/netns/$TNETNS" -- "$BINARY" \
    --overlay  "$VETH_A" \
    --underlay "$VETH_B" \
    --bpf-dir  "$STALE_BPF_DIR" \
    --pin-dir  /sys/fs/bpf \
    --duration 1s \
    >"$_STDERR_TMP" 2>&1
_EXIT=$?
set -e
_STDERR=$(cat "$_STDERR_TMP"); rm -f "$_STDERR_TMP"
_info "binary exit code: $_EXIT"
_info "binary output:    $_STDERR"

# --------------------------------------------------------------------------
# Step 4: Assert non-zero exit code
# --------------------------------------------------------------------------
echo "[4] Checking exit code..."
if [[ $_EXIT -ne 0 ]]; then
    _pass "binary exited non-zero ($_EXIT) as expected"
else
    _fail "binary should have exited non-zero but returned 0"
fi

# --------------------------------------------------------------------------
# Step 5: Assert stderr contains the expected error string
# --------------------------------------------------------------------------
echo "[5] Checking error message..."
if echo "$_STDERR" | grep -q "vxlan_config map missing from tc_ingress object"; then
    _pass "stderr contains: vxlan_config map missing from tc_ingress object"
else
    _fail "expected 'vxlan_config map missing from tc_ingress object' in stderr"
    _fail "actual output: $_STDERR"
fi

# Confirm the fix instructions are also present
if echo "$_STDERR" | grep -q "make clean-bpf"; then
    _pass "stderr contains fix hint: make clean-bpf"
else
    _fail "expected 'make clean-bpf' fix hint in stderr"
fi

# --------------------------------------------------------------------------
# Step 6: Assert no TC filters remain on the underlay interface
# --------------------------------------------------------------------------
echo "[6] Checking TC filters after failed load..."
_FILTERS=$(ip netns exec "$TNETNS" tc filter show dev "$VETH_B" ingress 2>/dev/null || echo "")
if [[ -z "$_FILTERS" ]]; then
    _pass "no TC filters on $VETH_B ingress (loader rolled back correctly)"
else
    _fail "TC filters found on $VETH_B ingress after failed load:"
    echo "$_FILTERS"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
