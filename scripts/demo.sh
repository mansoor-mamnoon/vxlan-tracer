#!/usr/bin/env bash
# scripts/demo.sh
#
# Quick demonstration of vxlan-tracer detecting VXLAN_FRAGMENTATION_OBSERVED.
#
# Reproduces the stale-MTU scenario: overlay MTU 1450 vs underlay MTU 1400.
# Large traffic (ping -s 1360 → outer IP 1438 B > 1400 B underlay) triggers
# ip_do_fragment. vxlan-tracer reports VXLAN_FRAGMENTATION_OBSERVED.
#
# What this demonstrates:
#   - eBPF TC egress hook records oversized VXLAN outer packets
#   - ip_do_fragment kprobe fires and counts fragmentation events
#   - Both signals together → global_corroborated fragmentation verdict
#   - Recommended overlay MTU is printed (underlay MTU - 50 = 1350)
#
# Requirements: Linux, root, compiled binary and BPF objects
# Duration: approximately 25 seconds
#
# Usage:
#   sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf bash scripts/demo.sh
#   make demo  (wraps this script)

set -uo pipefail

BINARY="${BINARY:-dist/vxlan-tracer}"
BPF_DIR="${BPF_DIR:-bpf}"
PIN_DIR="${PIN_DIR:-/sys/fs/bpf/vxlan-tracer-demo}"
DURATION="${DURATION:-15s}"
NETNS="demo-ns1"
NS2="demo-ns2"
VETH1="demo-veth1"
VETH2="demo-veth2"
OVERLAY="vxlan0"
UNDERLAY="$VETH1"
VXLAN_PORT=4789

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: demo requires Linux" >&2; exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: demo requires root (sudo)" >&2; exit 1
fi
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found: $BINARY — run 'make build' first" >&2; exit 1
fi
for _o in tc_ingress_eth0.bpf.o tc_egress_vxlan0.bpf.o kprobes.bpf.o frag_kprobes.bpf.o; do
    if [[ ! -f "$BPF_DIR/$_o" ]]; then
        echo "ERROR: BPF object missing: $BPF_DIR/$_o — run 'make bpf' on Linux first" >&2
        exit 1
    fi
done

# --------------------------------------------------------------------------
# Cleanup function (runs on exit, success or failure)
# --------------------------------------------------------------------------
_teardown() {
    ip netns del "$NETNS" 2>/dev/null || true
    ip netns del "$NS2"   2>/dev/null || true
    ip link del "$VETH1"  2>/dev/null || true
    rm -rf "$PIN_DIR"
    # Cleanup clsact qdisc on veth that stays in global ns before move
    true
}
trap _teardown EXIT

# --------------------------------------------------------------------------
# Setup: stale-MTU VXLAN lab (two namespaces, one VXLAN device)
# --------------------------------------------------------------------------
echo ""
echo "=== vxlan-tracer demo: VXLAN fragmentation detection ==="
echo ""

# Tear down any leftover state from a prior run
ip netns del "$NETNS" 2>/dev/null || true
ip netns del "$NS2"   2>/dev/null || true
ip link del "$VETH1"  2>/dev/null || true

echo "[setup] Creating namespaces and veth pair..."
ip netns add "$NETNS"
ip netns add "$NS2"
ip link add "$VETH1" type veth peer name "$VETH2"
ip link set "$VETH1" netns "$NETNS"
ip link set "$VETH2" netns "$NS2"

ip netns exec "$NETNS" ip addr add 192.168.100.1/24 dev "$VETH1"
ip netns exec "$NETNS" ip link set "$VETH1" up mtu 1500
ip netns exec "$NETNS" ip link set lo up
ip netns exec "$NS2"   ip addr add 192.168.100.2/24 dev "$VETH2"
ip netns exec "$NS2"   ip link set "$VETH2" up mtu 1500
ip netns exec "$NS2"   ip link set lo up

echo "[setup] Creating VXLAN overlay (port $VXLAN_PORT, VNI 42)..."
ip netns exec "$NETNS" \
    ip link add vxlan0 type vxlan \
        id 42 dstport "$VXLAN_PORT" \
        local 192.168.100.1 remote 192.168.100.2 \
        dev "$VETH1" nolearning
ip netns exec "$NETNS" ip addr add 10.244.0.1/24 dev vxlan0
ip netns exec "$NETNS" ip link set vxlan0 up
ip netns exec "$NETNS" ip neigh add 10.244.0.2 lladdr de:ad:be:ef:00:02 dev vxlan0

ip netns exec "$NS2" \
    ip link add vxlan0 type vxlan \
        id 42 dstport "$VXLAN_PORT" \
        local 192.168.100.2 remote 192.168.100.1 \
        dev "$VETH2" nolearning
ip netns exec "$NS2" ip addr add 10.244.0.2/24 dev vxlan0
ip netns exec "$NS2" ip link set vxlan0 up
ip netns exec "$NS2" ip neigh add 10.244.0.1 lladdr de:ad:be:ef:00:01 dev vxlan0

echo "[setup] Reducing underlay MTU to 1400 (vxlan0 stays at 1450 — stale MTU)..."
ip netns exec "$NETNS" ip link set "$VETH1" mtu 1400
ip netns exec "$NS2"   ip link set "$VETH2" mtu 1400

echo "[setup] Lab ready:"
echo "  vxlan0 MTU: $(ip netns exec "$NETNS" ip link show vxlan0 | grep -oP 'mtu \K\d+')"
echo "  $VETH1 MTU: $(ip netns exec "$NETNS" ip link show "$VETH1" | grep -oP 'mtu \K\d+')"
echo ""

# --------------------------------------------------------------------------
# Mount bpffs if needed
# --------------------------------------------------------------------------
if ! mount | grep -q 'type bpf'; then
    mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
fi
mkdir -p "$PIN_DIR"

# --------------------------------------------------------------------------
# Run vxlan-tracer in the background
# --------------------------------------------------------------------------
_LOG="/tmp/vxlan-demo-$$.json"
echo "[demo] Starting vxlan-tracer (${DURATION} window)..."
nsenter --net="/var/run/netns/$NETNS" -- "$BINARY" \
    --overlay  vxlan0 \
    --underlay "$VETH1" \
    --bpf-dir  "$BPF_DIR" \
    --pin-dir  "$PIN_DIR" \
    --duration "$DURATION" \
    --json \
    >"$_LOG" 2>/dev/null &
_PID=$!

# Give the binary time to attach
sleep 4

# --------------------------------------------------------------------------
# Generate oversized traffic (outer IP 1438 B > 1400 B underlay MTU)
# --------------------------------------------------------------------------
echo "[demo] Sending large traffic (inner IP ~1388 B → outer IP ~1438 B > 1400 B underlay)..."
ip netns exec "$NETNS" ping -c 5 -s 1360 -q 10.244.0.2 2>/dev/null || true

echo "[demo] Waiting for vxlan-tracer to finish..."
wait "$_PID" 2>/dev/null || true

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
echo ""
echo "=== Result ==="
echo ""

# Human-readable output
if [[ -f "$_LOG" ]] && [[ -s "$_LOG" ]]; then
    # Show JSON
    echo "JSON output:"
    cat "$_LOG"
    echo ""

    # Extract key fields for a summary
    _VERDICT=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verdict'])" <"$_LOG" 2>/dev/null || echo "unknown")
    _FRAG=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('frag_events_total',0))" <"$_LOG" 2>/dev/null || echo "?")
    _OUTER=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('max_outer_ip_len',0))" <"$_LOG" 2>/dev/null || echo "?")
    _UMTU=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('underlay_mtu',0))" <"$_LOG" 2>/dev/null || echo "?")
    _REC=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('recommended_overlay_mtu',0))" <"$_LOG" 2>/dev/null || echo "?")

    echo "Summary:"
    echo "  Verdict:                $_VERDICT"
    echo "  ip_do_fragment events:  $_FRAG"
    echo "  Largest outer IP seen:  ${_OUTER} B"
    echo "  Underlay MTU:           ${_UMTU} B"
    if [[ "$_REC" != "0" ]]; then
        echo "  Recommended overlay MTU: ${_REC} B (= underlay − 50)"
    fi
    echo ""

    if [[ "$_VERDICT" == "VXLAN_FRAGMENTATION_OBSERVED" ]]; then
        echo "  DEMO PASSED: vxlan-tracer correctly identified VXLAN fragmentation."
        echo "  In a cloud environment, these fragmented outer VXLAN packets may be"
        echo "  dropped silently, causing large-request blackholes."
    else
        echo "  NOTE: expected VXLAN_FRAGMENTATION_OBSERVED, got $_VERDICT"
        echo "  (Traffic may not have been large enough, or timing was off.)"
    fi
else
    echo "  WARNING: no output from vxlan-tracer (binary may have failed or traffic too fast)"
    echo "  Try increasing DURATION: DURATION=25s sudo ... bash scripts/demo.sh"
fi

echo ""
echo "=== vxlan-tracer demo complete ==="
rm -f "$_LOG"
