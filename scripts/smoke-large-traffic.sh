#!/usr/bin/env bash
# scripts/smoke-large-traffic.sh
#
# Attempts to reproduce VXLAN MTU blackhole with large transfers.
# Records ACTUAL behavior — does not force a specific outcome.
#
# Expected in a local netns+veth topology with DF=0 (default):
#   - ip_do_fragment WILL fire (outer packets fragmented)
#   - BUT ns2 may still reassemble fragments (no middlebox to drop them)
#   - So large transfer may partially succeed or complete despite fragmentation
#   - The hard blackhole requires df=set on vxlan0 or an iptables DROP rule
#
# See docs/lab-topology.md "Note on local netns topologies" for details.

set -uo pipefail

NS1="ns1"
OVERLAY_IP2="10.244.0.2"
TIMEOUT=20
PASS=0
FAIL=0
PARTIAL=0

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

echo "=== smoke-large-traffic ==="
echo "Testing large packet flows — recording actual behavior (not forcing a result)."
echo "Timeout per test: ${TIMEOUT}s"
echo ""

# Test 1: ping with payload that exceeds safe VXLAN MTU
# inner IP = 1480 bytes → outer frame = 1544 bytes (exceeds 1500 by 44)
echo "[1] Overlay ping ns1 → ns2 (1452B payload, projected outer 1544B > 1500)..."
PING_OUT=$(ip netns exec "$NS1" ping -c 5 -W 3 -q -s 1452 "$OVERLAY_IP2" 2>&1 || true)
echo "    raw output:"
echo "$PING_OUT" | sed 's/^/      /'
LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)' || echo "unknown")
RECV=$(echo "$PING_OUT" | grep -oP '\d+ received' | grep -oP '\d+' || echo "0")
if [[ "$LOSS" == "100" ]] || [[ "$RECV" == "0" ]]; then
    echo "  → BLACKHOLE: all packets dropped"
    FAIL=$((FAIL + 1))
elif [[ "$LOSS" -gt 0 ]] 2>/dev/null; then
    echo "  → PARTIAL: some packets lost ($LOSS%) — likely fragmentation + partial drop"
    PARTIAL=$((PARTIAL + 1))
else
    echo "  → PASS (fragmented packets reassembled in ns2 — middlebox would drop these)"
    PASS=$((PASS + 1))
fi

# Test 2: large file download
echo ""
echo "[2] Large HTTP GET ns1 → ns2 (large.bin ~5MB), timeout=${TIMEOUT}s..."
START_BYTES=0
END_BYTES=0
START_TS=$(date +%s%N)

# curl writes progress to stderr with -# flag
CURL_RC=0
CURL_OUT=$(ip netns exec "$NS1" curl -sf \
    --max-time "$TIMEOUT" \
    --limit-rate 100M \
    -w "bytes=%{size_download} speed=%{speed_download} http=%{http_code}" \
    "http://$OVERLAY_IP2/large.bin" \
    -o /tmp/smoke-large-download.bin 2>/tmp/smoke-large-curl.err) || CURL_RC=$?

END_TS=$(date +%s%N)
ELAPSED=$(( (END_TS - START_TS) / 1000000 ))

if [[ -f /tmp/smoke-large-download.bin ]]; then
    ACTUAL_BYTES=$(wc -c < /tmp/smoke-large-download.bin 2>/dev/null || echo 0)
else
    ACTUAL_BYTES=0
fi

echo "    curl exit code: $CURL_RC"
echo "    elapsed: ${ELAPSED}ms"
echo "    bytes received: $ACTUAL_BYTES"
echo "    curl stats: $CURL_OUT"
if [[ -s /tmp/smoke-large-curl.err ]]; then
    echo "    curl stderr: $(cat /tmp/smoke-large-curl.err | head -c 120)"
fi

if [[ $CURL_RC -eq 0 ]]; then
    echo "  → PASS: full download completed (fragments reassembled — middlebox would stall this)"
    PASS=$((PASS + 1))
elif [[ $CURL_RC -eq 28 ]]; then
    echo "  → TIMEOUT at ${TIMEOUT}s after ${ACTUAL_BYTES} bytes — likely blackhole"
    FAIL=$((FAIL + 1))
elif [[ $ACTUAL_BYTES -gt 0 ]]; then
    echo "  → PARTIAL: received ${ACTUAL_BYTES} bytes then failed (rc=$CURL_RC)"
    PARTIAL=$((PARTIAL + 1))
else
    echo "  → FAIL: no bytes received (rc=$CURL_RC)"
    FAIL=$((FAIL + 1))
fi

# Test 3: ping at exact boundary (inner IP 1450 bytes → outer frame 1514 bytes, 14 over 1500)
echo ""
echo "[3] Boundary ping (1422B payload, projected outer frame 1500B — exact limit)..."
PING_BOUNDARY=$(ip netns exec "$NS1" ping -c 3 -W 3 -q -s 1422 "$OVERLAY_IP2" 2>&1 || true)
echo "$PING_BOUNDARY" | sed 's/^/    /'

echo ""
echo "=== Results: $PASS passed, $PARTIAL partial, $FAIL failed ==="
echo ""
echo "Key interpretation:"
echo "  PASS on large tests in a local netns: expected when no middlebox drops DF=0 fragments."
echo "  This does NOT mean the tool is unnecessary — ip_do_fragment still fires."
echo "  Use 'bpftrace spikes/bpftrace/ip_do_fragment.bt' to confirm fragmentation events."
echo "  To reproduce a hard blackhole: add 'df set' to the vxlan0 creation command."
echo "  See docs/lab-topology.md for details."
