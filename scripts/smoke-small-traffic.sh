#!/usr/bin/env bash
# scripts/smoke-small-traffic.sh
#
# Tests that small traffic crosses the VXLAN overlay.
# Must run after setup-netns.sh.
# Does NOT require root (reads only; ping inside ns1 does).
# Actually needs: sudo ip netns exec ns1 ...
# So run via: sudo make smoke-small  OR  sudo bash scripts/smoke-small-traffic.sh

set -euo pipefail

NS1="ns1"
OVERLAY_IP2="10.244.0.2"
UNDERLAY_IP2="192.168.100.2"
PASS=0
FAIL=0

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

result() {
    local label="$1" status="$2" detail="$3"
    if [[ "$status" == "PASS" ]]; then
        echo "  [PASS] $label — $detail"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label — $detail"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== smoke-small-traffic ==="
echo "Testing small packet flows across ns1 → ns2 VXLAN overlay."
echo "Expected: all pass (small packets fit within MTU)"
echo ""

# Test 1: underlay ping (sanity)
echo "[1] Underlay ping ns1 → ns2 (ICMP 56B payload, underlay)..."
if ip netns exec "$NS1" ping -c 3 -W 2 -q "$UNDERLAY_IP2" > /tmp/smoke-small.log 2>&1; then
    LOSS=$(grep -oP '\d+(?=% packet loss)' /tmp/smoke-small.log || echo "?")
    result "underlay ping" "PASS" "$LOSS% loss"
else
    result "underlay ping" "FAIL" "ping failed — check lab setup"
fi

# Test 2: overlay ping small (inner IP ~84 bytes → outer frame ~148 bytes, well under 1500)
echo "[2] Overlay ping ns1 → ns2 (ICMP 56B payload, vxlan0)..."
if ip netns exec "$NS1" ping -c 3 -W 2 -q "$OVERLAY_IP2" > /tmp/smoke-small-overlay.log 2>&1; then
    LOSS=$(grep -oP '\d+(?=% packet loss)' /tmp/smoke-small-overlay.log || echo "?")
    RTT=$(grep -oP 'min/avg/max[^=]+=\K[0-9.]+' /tmp/smoke-small-overlay.log || echo "?")
    result "overlay ping (56B)" "PASS" "$LOSS% loss, min_rtt=${RTT}ms"
else
    result "overlay ping (56B)" "FAIL" "ping failed"
fi

# Test 3: larger ping that still fits (inner IP ~1428 bytes → outer frame ~1492 bytes ≤ 1500)
echo "[3] Overlay ping ns1 → ns2 (1400B payload, projected outer 1492B ≤ 1500)..."
if ip netns exec "$NS1" ping -c 3 -W 2 -q -s 1400 "$OVERLAY_IP2" > /tmp/smoke-small-1400.log 2>&1; then
    LOSS=$(grep -oP '\d+(?=% packet loss)' /tmp/smoke-small-1400.log || echo "?")
    result "overlay ping (1400B)" "PASS" "$LOSS% loss"
else
    result "overlay ping (1400B)" "FAIL" "ping failed — could be fragmentation"
fi

# Test 4: small HTTP request
echo "[4] Small HTTP GET from ns1 → ns2 HTTP server (small.txt)..."
if ip netns exec "$NS1" curl -sf --max-time 5 "http://$OVERLAY_IP2/small.txt" \
    -o /tmp/smoke-small-http.out 2>/tmp/smoke-small-http.err; then
    CONTENT=$(cat /tmp/smoke-small-http.out | head -c 80)
    result "HTTP GET small.txt" "PASS" "response: '$CONTENT'"
else
    HTTP_ERR=$(cat /tmp/smoke-small-http.err | head -c 80)
    result "HTTP GET small.txt" "FAIL" "curl error: $HTTP_ERR"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    echo "NOTE: Failures may indicate:"
    echo "  - Lab not set up (run: sudo make lab-up)"
    echo "  - HTTP server not running in ns2 (check /tmp/vxlan-lab-http.log)"
    exit 1
fi
