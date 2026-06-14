#!/usr/bin/env bash
# scripts/setup-netns.sh
#
# Creates the two-namespace VXLAN lab topology.
# Must run as root.
# Tested on Linux 5.15+. Does NOT run on macOS.
#
# After setup:
#   ns1: vxlan0=10.244.0.1/24, veth1=192.168.100.1/24
#   ns2: vxlan0=10.244.0.2/24, veth2=192.168.100.2/24
#   VXLAN VNI 42, port 4789, vxlan0 MTU intentionally 1500 (wrong: should be 1450)

set -euo pipefail

NS1="ns1"
NS2="ns2"
VETH1="veth1"
VETH2="veth2"
UNDERLAY_IP1="192.168.100.1"
UNDERLAY_IP2="192.168.100.2"
OVERLAY_IP1="10.244.0.1"
OVERLAY_IP2="10.244.0.2"
VNI=42
VXLAN_PORT=4789
WRONG_MTU=1500       # intentionally wrong; correct is 1450
UNDERLAY_MTU=1500
WWW_DIR="/tmp/vxlan-lab-www"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux. macOS does not support network namespaces." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

echo "[setup] Cleaning up any existing topology..."
bash "$(dirname "$0")/teardown-netns.sh" 2>/dev/null || true

echo "[setup] Creating network namespaces..."
ip netns add "$NS1"
ip netns add "$NS2"

echo "[setup] Creating veth pair $VETH1 <-> $VETH2..."
ip link add "$VETH1" type veth peer name "$VETH2"
ip link set "$VETH1" netns "$NS1"
ip link set "$VETH2" netns "$NS2"

echo "[setup] Configuring $NS1 underlay ($VETH1 $UNDERLAY_IP1/24)..."
ip netns exec "$NS1" ip addr add "$UNDERLAY_IP1/24" dev "$VETH1"
ip netns exec "$NS1" ip link set "$VETH1" up mtu "$UNDERLAY_MTU"
ip netns exec "$NS1" ip link set lo up

echo "[setup] Configuring $NS2 underlay ($VETH2 $UNDERLAY_IP2/24)..."
ip netns exec "$NS2" ip addr add "$UNDERLAY_IP2/24" dev "$VETH2"
ip netns exec "$NS2" ip link set "$VETH2" up mtu "$UNDERLAY_MTU"
ip netns exec "$NS2" ip link set lo up

echo "[setup] Creating VXLAN interface in $NS1 (wrong MTU=$WRONG_MTU)..."
ip netns exec "$NS1" ip link add vxlan0 type vxlan \
    id "$VNI" \
    remote "$UNDERLAY_IP2" \
    local "$UNDERLAY_IP1" \
    dstport "$VXLAN_PORT" \
    dev "$VETH1"
ip netns exec "$NS1" ip addr add "$OVERLAY_IP1/24" dev vxlan0
ip netns exec "$NS1" ip link set vxlan0 up mtu "$WRONG_MTU"

echo "[setup] Creating VXLAN interface in $NS2 (wrong MTU=$WRONG_MTU)..."
ip netns exec "$NS2" ip link add vxlan0 type vxlan \
    id "$VNI" \
    remote "$UNDERLAY_IP1" \
    local "$UNDERLAY_IP2" \
    dstport "$VXLAN_PORT" \
    dev "$VETH2"
ip netns exec "$NS2" ip addr add "$OVERLAY_IP2/24" dev vxlan0
ip netns exec "$NS2" ip link set vxlan0 up mtu "$WRONG_MTU"

echo "[setup] Verifying underlay reachability..."
ip netns exec "$NS1" ping -c 1 -W 2 "$UNDERLAY_IP2" > /dev/null \
    && echo "[setup] underlay ping: OK" \
    || echo "[setup] WARNING: underlay ping failed"

echo "[setup] Verifying overlay reachability (small ping)..."
ip netns exec "$NS1" ping -c 1 -W 2 "$OVERLAY_IP2" > /dev/null \
    && echo "[setup] overlay ping (small): OK" \
    || echo "[setup] WARNING: overlay small ping failed"

echo "[setup] Creating HTTP server content in $WWW_DIR..."
mkdir -p "$WWW_DIR"
echo "vxlan-tracer lab: small file" > "$WWW_DIR/small.txt"
dd if=/dev/urandom bs=1M count=5 2>/dev/null | base64 > "$WWW_DIR/large.bin"
echo "[setup] Created large.bin (5MB base64)"

echo "[setup] Starting Python HTTP server in $NS2 on $OVERLAY_IP2:80..."
ip netns exec "$NS2" python3 -m http.server 80 \
    --directory "$WWW_DIR" \
    --bind "$OVERLAY_IP2" \
    > /tmp/vxlan-lab-http.log 2>&1 &
HTTP_PID=$!
echo "[setup] HTTP server PID: $HTTP_PID (log: /tmp/vxlan-lab-http.log)"
sleep 0.5

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "[setup] WARNING: HTTP server failed to start. Check /tmp/vxlan-lab-http.log"
fi

echo ""
echo "Lab topology ready:"
echo "  ns1: vxlan0=$OVERLAY_IP1/24  veth1=$UNDERLAY_IP1/24  (vxlan0 MTU=$WRONG_MTU — intentionally wrong)"
echo "  ns2: vxlan0=$OVERLAY_IP2/24  veth2=$UNDERLAY_IP2/24  (vxlan0 MTU=$WRONG_MTU)"
echo "  VNI=$VNI  port=$VXLAN_PORT  underlay_MTU=$UNDERLAY_MTU"
echo ""
echo "Run smoke tests:"
echo "  make smoke-small"
echo "  make smoke-large"
echo ""
echo "Correct vxlan0 MTU: $((UNDERLAY_MTU - 50))"
echo "For TCP MSS=1460 with wrong MTU:"
echo "  inner IP = 1500, outer IP = $((1500 + 50)) bytes (excess $((1500 + 50 - UNDERLAY_MTU)) over underlay MTU $UNDERLAY_MTU)"
echo "  wire frame on the wire = $((1500 + 64)) bytes (outer ETH 14 + outer IP 1550; informational only)"
