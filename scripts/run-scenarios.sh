#!/usr/bin/env bash
# scripts/run-scenarios.sh
#
# Automated scenario runner for vxlan-tracer.
# Runs four diagnostic scenarios in order and asserts expected verdicts.
# Each scenario performs its own cleanup before starting.
#
# Requirements:
#   - Linux, root
#   - BPF objects compiled into BPF_DIR
#   - vxlan-tracer binary at BINARY path
#   - python3 + scapy (for PTB injection scenarios)
#
# Usage:
#   BINARY=/tmp/vxlan-tracer-linux-arm64 BPF_DIR=/tmp/bpfobjs bash scripts/run-scenarios.sh
#
# Exit codes:
#   0  all scenarios produced the expected verdict
#   1  one or more scenarios produced an unexpected verdict or tool error

set -uo pipefail

BINARY="${BINARY:-/usr/local/bin/vxlan-tracer}"
BPF_DIR="${BPF_DIR:-/tmp/bpfobjs}"
PIN_DIR="${PIN_DIR:-/sys/fs/bpf/vxlan-tracer}"
NETNS="${NETNS:-ns1}"
OVERLAY="${OVERLAY:-vxlan0}"
UNDERLAY="${UNDERLAY:-veth1}"
DURATION="${DURATION:-15s}"

PASS=0
FAIL=0

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY" >&2
    exit 1
fi

_cleanup() {
    echo "[scenario] Cleanup..."
    NETNS="$NETNS" OVERLAY="$OVERLAY" UNDERLAY="$UNDERLAY" PIN_DIR="$PIN_DIR" \
        bash "$(dirname "$0")/cleanup-bpf.sh" 2>&1 | grep -v "^$" | sed 's/^/  /'
}

_setup() {
    echo "[scenario] Setting up lab..."
    bash "$(dirname "$0")/setup-netns.sh" 2>&1 | tail -20 | sed 's/^/  /'
}

_run() {
    local scenario="$1" expected_verdict="$2" extra_flags="${3:-}"
    echo ""
    echo "=========================================="
    echo "Scenario: $scenario"
    echo "Expected verdict: $expected_verdict"
    echo "=========================================="

    _cleanup
    _setup

    local logfile="/tmp/scenario-${scenario// /-}.log"
    # shellcheck disable=SC2086
    nsenter --net="/var/run/netns/$NETNS" -- "$BINARY" \
        --overlay "$OVERLAY" --underlay "$UNDERLAY" \
        --pin-dir "$PIN_DIR" --bpf-dir "$BPF_DIR" \
        --duration "$DURATION" --json $extra_flags \
        >"$logfile" 2>&1 &
    GOPID=$!

    # Trigger scenario-specific traffic after binary has had time to attach
    sleep 4
    _traffic_"$1" 2>&1 | sed 's/^/  [traffic] /'

    wait $GOPID
    local exit_code=$?
    local actual_json
    actual_json=$(grep '^{' "$logfile" | tail -1)

    echo ""
    echo "[scenario] Binary exit code: $exit_code"
    echo "[scenario] Raw JSON: $actual_json"

    if [[ $exit_code -ne 0 ]]; then
        echo "[FAIL] Binary exited with code $exit_code (expected 0)" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi

    local actual_verdict
    actual_verdict=$(echo "$actual_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('verdict','MISSING'))" 2>/dev/null || echo "JSON_PARSE_ERROR")

    if [[ "$actual_verdict" == "$expected_verdict" ]]; then
        echo "[PASS] verdict=$actual_verdict"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] Expected verdict=$expected_verdict, got=$actual_verdict" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Traffic generators — called after 4s sleep inside _run
_traffic_healthy_small() {
    ip netns exec "$NETNS" ping -c 5 -s 40 10.244.0.2
}

_traffic_fragmentation() {
    ip netns exec "$NETNS" ping -c 3 -s 1360 10.244.0.2
}

_traffic_ptb_delivered() {
    # Remove any iptables DROP rule; inject 5 synthetic PTBs
    ip netns exec "$NETNS" iptables -D INPUT -p icmp --icmp-type 3/4 -j DROP 2>/dev/null || true
    ip netns exec ns2 python3 spikes/inject_ptb.py \
        --src 192.168.100.2 --dst 192.168.100.1 \
        --dev veth2 --next-hop-mtu 1400 --count 5
}

_traffic_ptb_suppressed() {
    # Install iptables DROP rule before injecting
    ip netns exec "$NETNS" iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP
    ip netns exec ns2 python3 spikes/inject_ptb.py \
        --src 192.168.100.2 --dst 192.168.100.1 \
        --dev veth2 --next-hop-mtu 1400 --count 5
}

# Run the four scenarios
_run "healthy_small"    "VXLAN_MTU_MISCONFIGURATION"
_run "fragmentation"    "VXLAN_FRAGMENTATION_OBSERVED"
_run "ptb_delivered"    "PTB_DELIVERED"
_run "ptb_suppressed"   "PTB_SUPPRESSED"

# Teardown
echo ""
echo "=========================================="
echo "All scenarios complete. Tearing down lab..."
bash "$(dirname "$0")/teardown-netns.sh" 2>&1 | tail -5 | sed 's/^/  /'

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
