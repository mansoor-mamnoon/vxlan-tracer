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

# --- Preflight checks ---
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (sudo or root user)." >&2
    exit 1
fi

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY" >&2
    echo "  Build with: make build  (on Linux) or GOOS=linux GOARCH=arm64 go build ..." >&2
    exit 1
fi

if [[ ! -d "$BPF_DIR" ]]; then
    echo "ERROR: BPF_DIR not found: $BPF_DIR" >&2
    echo "  Compile BPF objects with: make bpf  (on Linux with clang installed)" >&2
    exit 1
fi

for _bpf_obj in tc_ingress_eth0.bpf.o tc_egress_vxlan0.bpf.o kprobes.bpf.o frag_kprobes.bpf.o; do
    if [[ ! -f "$BPF_DIR/$_bpf_obj" ]]; then
        echo "ERROR: BPF object missing: $BPF_DIR/$_bpf_obj" >&2
        echo "  Run: make bpf  (from the repo root on Linux)" >&2
        exit 1
    fi
done

for _cmd in ip iptables python3 nsenter; do
    if ! command -v "$_cmd" &>/dev/null; then
        echo "ERROR: required command not found: $_cmd" >&2
        case "$_cmd" in
            ip|iptables) echo "  Install: apt-get install -y iproute2 iptables" >&2 ;;
            python3)     echo "  Install: apt-get install -y python3 python3-pip && pip3 install scapy" >&2 ;;
            nsenter)     echo "  Install: apt-get install -y util-linux" >&2 ;;
        esac
        exit 1
    fi
done

if ! python3 -c "import scapy" 2>/dev/null; then
    echo "ERROR: python3 scapy module not found (required for PTB injection)." >&2
    echo "  Install: pip3 install scapy" >&2
    exit 1
fi

if ! mount | grep -q 'type bpf'; then
    echo "WARN: bpffs does not appear to be mounted at /sys/fs/bpf." >&2
    echo "  Attempting to mount: mount -t bpf bpf /sys/fs/bpf" >&2
    mount -t bpf bpf /sys/fs/bpf 2>/dev/null || {
        echo "ERROR: bpffs mount failed. Run: sudo bash scripts/setup-bpf-fs.sh" >&2
        exit 1
    }
fi

if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
    echo "ERROR: /sys/kernel/btf/vmlinux not found." >&2
    echo "  CO-RE BPF programs require kernel built with CONFIG_DEBUG_INFO_BTF=y." >&2
    echo "  Ubuntu 20.04+ ships BTF by default. Try a different kernel." >&2
    exit 1
fi

echo "[preflight] OK: Linux $(uname -r), root, binary=$BINARY, BPF_DIR=$BPF_DIR, BTF present"

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

_run_second() {
    # Second run in the same namespaces (no setup, cleanup only).
    # Tests idempotency: same namespaces, same lab topology, no container restart.
    # Route MTU cache is flushed between runs to ensure max_outer_ip_len is fresh.
    local scenario="$1" expected_verdict="$2"
    echo ""
    echo "=========================================="
    echo "Scenario: ${scenario} (SECOND RUN — no teardown)"
    echo "Expected verdict: $expected_verdict"
    echo "Accepts either: $expected_verdict (corroborated or global_unscoped)"
    echo "=========================================="

    _cleanup

    # Flush route/PMTU cache in both namespaces to reset max_outer_ip_len baseline.
    # Without this, route MTU cache from the first run may reduce outer packet sizes
    # below the underlay MTU, preventing the corroborated two-signal verdict.
    ip netns exec "$NETNS" ip route flush cache 2>/dev/null && \
        echo "[scenario] Route cache flushed in $NETNS" || \
        echo "[scenario] Route cache flush not available or no-op"
    ip netns exec ns2 ip route flush cache 2>/dev/null || true

    local logfile="/tmp/scenario-${scenario// /-}-run2.log"
    # shellcheck disable=SC2086
    nsenter --net="/var/run/netns/$NETNS" -- "$BINARY" \
        --overlay "$OVERLAY" --underlay "$UNDERLAY" \
        --pin-dir "$PIN_DIR" --bpf-dir "$BPF_DIR" \
        --duration "$DURATION" --json \
        >"$logfile" 2>&1 &
    GOPID=$!

    sleep 4
    _traffic_"$scenario" 2>&1 | sed 's/^/  [traffic] /'

    wait $GOPID
    local exit_code=$?
    local actual_json
    actual_json=$(grep '^{' "$logfile" | tail -1)

    echo ""
    echo "[scenario] Binary exit code: $exit_code"
    echo "[scenario] Raw JSON: $actual_json"

    if [[ $exit_code -ne 0 ]]; then
        echo "[FAIL] Second run: binary exited with code $exit_code (expected 0)" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi

    local actual_verdict frag_scope
    actual_verdict=$(echo "$actual_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('verdict','MISSING'))" 2>/dev/null || echo "JSON_PARSE_ERROR")
    frag_scope=$(echo "$actual_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fragmentation_scope','(absent)'))" 2>/dev/null || echo "(parse error)")

    echo "[scenario] fragmentation_scope: $frag_scope"

    if [[ "$actual_verdict" == "$expected_verdict" ]]; then
        echo "[PASS] Second run: verdict=$actual_verdict scope=$frag_scope"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] Second run: expected=$expected_verdict got=$actual_verdict" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Run the four scenarios
_run "healthy_small"    "VXLAN_MTU_MISCONFIGURATION"
_run "fragmentation"    "VXLAN_FRAGMENTATION_OBSERVED"
_run "ptb_delivered"    "PTB_DELIVERED"
_run "ptb_suppressed"   "PTB_SUPPRESSED"

# Scenario 5: second run of fragmentation in the same namespaces (no teardown)
# Tests that idempotent cleanup + route cache flush allows a fresh verdict.
_run_second "fragmentation" "VXLAN_FRAGMENTATION_OBSERVED"

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
