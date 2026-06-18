#!/usr/bin/env bash
# scripts/setup-netns.sh
#
# Creates a two-namespace VXLAN lab that reproduces the MTU blackhole condition.
# Must run as root. Requires Linux. Does NOT run on macOS.
#
# Topology:
#   ns1: vxlan0=10.244.0.1/24 (MTU auto-set by kernel), veth1=192.168.100.1/24
#   ns2: vxlan0=10.244.0.2/24 (MTU auto-set by kernel), veth2=192.168.100.2/24
#   VXLAN VNI 42, port 4789
#
# Blackhole reproduction strategy:
#   Kernel 6.10+ enforces correct vxlan0 MTU at creation time and rejects
#   attempts to set it higher than (underlay_mtu - 50). We cannot reproduce
#   the classic Flannel misconfiguration (vxlan0 MTU=1500 with underlay MTU=1500)
#   directly on this kernel.
#
#   Instead: create vxlan0 while underlay MTU=1500 (kernel sets vxlan0 MTU=1450),
#   then reduce underlay MTU to 1400 AFTER vxlan0 creation. The kernel does not
#   auto-adjust vxlan0 MTU when underlay changes. Now:
#     - vxlan0 MTU=1450 (stale; was correct for underlay 1500)
#     - underlay MTU=1400
#     - max safe inner IP for underlay 1400: 1400 - 50 = 1350
#     - inner IP > 1350 → outer IP > 1400 → ip_do_fragment fires (DF=0 default)
#
#   This reproduces the real ops scenario: underlay MTU changed without updating
#   overlay MTU (e.g., cloud provider reduced jumbo frames, or team added a VPN
#   appliance with lower MTU in the underlay path).

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
# VXLAN_PORT can be set in the environment to override the default.
# k3s/Flannel uses 8472; the IANA-assigned default is 4789.
VXLAN_PORT=${VXLAN_PORT:-4789}
INITIAL_UNDERLAY_MTU=1500   # underlay MTU during vxlan0 creation (kernel sets vxlan0=1450)
REDUCED_UNDERLAY_MTU=1400   # reduced after creation; vxlan0 stays at 1450 (stale)
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

echo "[setup] Configuring $NS1 underlay ($VETH1 $UNDERLAY_IP1/24, MTU=$INITIAL_UNDERLAY_MTU)..."
ip netns exec "$NS1" ip addr add "$UNDERLAY_IP1/24" dev "$VETH1"
ip netns exec "$NS1" ip link set "$VETH1" up mtu "$INITIAL_UNDERLAY_MTU"
ip netns exec "$NS1" ip link set lo up

echo "[setup] Configuring $NS2 underlay ($VETH2 $UNDERLAY_IP2/24, MTU=$INITIAL_UNDERLAY_MTU)..."
ip netns exec "$NS2" ip addr add "$UNDERLAY_IP2/24" dev "$VETH2"
ip netns exec "$NS2" ip link set "$VETH2" up mtu "$INITIAL_UNDERLAY_MTU"
ip netns exec "$NS2" ip link set lo up

echo "[setup] Creating VXLAN in $NS1 (kernel will auto-set MTU=$((INITIAL_UNDERLAY_MTU - 50)))..."
ip netns exec "$NS1" ip link add vxlan0 type vxlan \
    id "$VNI" \
    remote "$UNDERLAY_IP2" \
    local "$UNDERLAY_IP1" \
    dstport "$VXLAN_PORT" \
    dev "$VETH1"
ip netns exec "$NS1" ip addr add "$OVERLAY_IP1/24" dev vxlan0
ip netns exec "$NS1" ip link set vxlan0 up

echo "[setup] Creating VXLAN in $NS2 (kernel will auto-set MTU=$((INITIAL_UNDERLAY_MTU - 50)))..."
ip netns exec "$NS2" ip link add vxlan0 type vxlan \
    id "$VNI" \
    remote "$UNDERLAY_IP1" \
    local "$UNDERLAY_IP2" \
    dstport "$VXLAN_PORT" \
    dev "$VETH2"
ip netns exec "$NS2" ip addr add "$OVERLAY_IP2/24" dev vxlan0
ip netns exec "$NS2" ip link set vxlan0 up

VXLAN_MTU=$(ip netns exec "$NS1" ip link show vxlan0 | grep -oP 'mtu \K[0-9]+' | head -1)
echo "[setup] vxlan0 MTU after creation: $VXLAN_MTU (expected $((INITIAL_UNDERLAY_MTU - 50)))"

echo "[setup] Reducing underlay MTU to $REDUCED_UNDERLAY_MTU AFTER vxlan0 creation..."
echo "[setup]   vxlan0 MTU stays at $VXLAN_MTU (stale); underlay now $REDUCED_UNDERLAY_MTU"
echo "[setup]   max safe inner IP = $((REDUCED_UNDERLAY_MTU - 50)); inner IP > that → ip_do_fragment"
ip netns exec "$NS1" ip link set "$VETH1" mtu "$REDUCED_UNDERLAY_MTU"
ip netns exec "$NS2" ip link set "$VETH2" mtu "$REDUCED_UNDERLAY_MTU"

echo "[setup] Verifying underlay reachability..."
ip netns exec "$NS1" ping -c 1 -W 2 "$UNDERLAY_IP2" > /dev/null \
    && echo "[setup] underlay ping: OK" \
    || echo "[setup] WARNING: underlay ping failed"

echo "[setup] Verifying overlay reachability (small ping, payload 40B)..."
ip netns exec "$NS1" ping -c 1 -W 2 -s 40 "$OVERLAY_IP2" > /dev/null \
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

SAFE_MTU=$((REDUCED_UNDERLAY_MTU - 50))
echo ""
echo "Lab topology ready:"
echo "  ns1: vxlan0=$OVERLAY_IP1/24 (MTU=$VXLAN_MTU stale)  veth1=$UNDERLAY_IP1/24 (MTU=$REDUCED_UNDERLAY_MTU)"
echo "  ns2: vxlan0=$OVERLAY_IP2/24 (MTU=$VXLAN_MTU stale)  veth2=$UNDERLAY_IP2/24 (MTU=$REDUCED_UNDERLAY_MTU)"
echo "  VNI=$VNI  port=$VXLAN_PORT"
echo ""
echo "MTU arithmetic:"
echo "  underlay MTU:     $REDUCED_UNDERLAY_MTU"
echo "  VXLAN overhead:   50 bytes (inner ETH 14 + outer IP 20 + outer UDP 8 + VXLAN hdr 8)"
echo "  max safe inner IP: $SAFE_MTU (underlay $REDUCED_UNDERLAY_MTU - 50)"
echo "  vxlan0 MTU stale: $VXLAN_MTU (was correct for underlay $INITIAL_UNDERLAY_MTU; now too high)"
echo "  blackhole zone:   inner IP > $SAFE_MTU → outer IP > $REDUCED_UNDERLAY_MTU → ip_do_fragment"
echo ""
echo "Run smoke tests:"
echo "  make smoke-small   (payload 40B: inner IP 68B, outer IP 118B, safe)"
echo "  make smoke-large   (payload 1360B: inner IP 1388B, outer IP 1438B > $REDUCED_UNDERLAY_MTU → fragment)"
