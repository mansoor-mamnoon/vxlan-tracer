#!/usr/bin/env bash
# scripts/setup-bpf-fs.sh
#
# Ensures bpffs is mounted at /sys/fs/bpf and creates the vxlan-tracer pin
# directory. Must run as root. Safe to run multiple times (idempotent).
#
# Pinned maps live under /sys/fs/bpf/vxlan-tracer/ so they survive program
# reload and are accessible by stable path instead of kernel-assigned,
# reload-unstable map IDs. See docs/map-lifecycle.md for the full design.

set -euo pipefail

PIN_DIR="/sys/fs/bpf/vxlan-tracer"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux. macOS has no bpffs." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

echo "[setup-bpf-fs] Checking bpffs mount at /sys/fs/bpf..."
if mount | grep -q "on /sys/fs/bpf type bpf"; then
    echo "[setup-bpf-fs] bpffs already mounted."
else
    echo "[setup-bpf-fs] Mounting bpffs..."
    mount -t bpf bpf /sys/fs/bpf
    echo "[setup-bpf-fs] bpffs mounted."
fi

echo "[setup-bpf-fs] Creating pin directory $PIN_DIR..."
mkdir -p "$PIN_DIR"
echo "[setup-bpf-fs] Done."

echo ""
echo "Pinned map paths (once the loader attaches and pins):"
echo "  $PIN_DIR/ptb_ingress_counts   (per-VTEP-pair PTB counts, tc_ingress_eth0)"
echo "  $PIN_DIR/ptb_ingress_total    (global PTB-at-ingress total, tc_ingress_eth0)"
echo "  $PIN_DIR/icmp_rcv_total       (post-netfilter filtered PTB total, kprobes)"
echo "  $PIN_DIR/flow_state           (per-flow max inner/outer IP len, tc_egress_vxlan0)"
echo ""
echo "Inspect with: bpftool map dump pinned $PIN_DIR/<name>"
