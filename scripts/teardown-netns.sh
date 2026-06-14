#!/usr/bin/env bash
# scripts/teardown-netns.sh
#
# Removes the vxlan-tracer lab topology.
# Must run as root.
# Safe to run when topology does not exist (all steps are idempotent).

set -uo pipefail

NS1="ns1"
NS2="ns2"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

echo "[teardown] Stopping HTTP server in ns2 (if running)..."
# Kill any python3 http.server running inside ns2
ip netns exec "$NS2" pkill -f "python3 -m http.server" 2>/dev/null || true

echo "[teardown] Removing network namespaces..."
ip netns del "$NS1" 2>/dev/null && echo "[teardown] deleted $NS1" || echo "[teardown] $NS1 not found (ok)"
ip netns del "$NS2" 2>/dev/null && echo "[teardown] deleted $NS2" || echo "[teardown] $NS2 not found (ok)"

# veth pair is deleted automatically when namespace is removed.
# VXLAN interfaces inside the namespaces are also cleaned up.

echo "[teardown] Cleaning up lab files..."
rm -f /tmp/vxlan-lab-http.log
# Preserve /tmp/vxlan-lab-www in case user wants to inspect it.

echo "[teardown] Done."
