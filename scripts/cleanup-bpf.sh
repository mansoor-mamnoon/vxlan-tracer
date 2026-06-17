#!/usr/bin/env bash
# scripts/cleanup-bpf.sh
#
# Remove vxlan-tracer TC BPF filters and pinned BPF maps.
# Idempotent: safe to run multiple times; exits 0 even when artefacts are absent.
# Must run as root on Linux.
#
# Override with environment variables (all have safe defaults):
#   NETNS     network namespace containing the interfaces (default: ns1)
#   OVERLAY   VXLAN overlay interface inside NETNS (default: vxlan0)
#   UNDERLAY  underlay interface inside NETNS (default: veth1)
#   PIN_DIR   bpffs pin directory on the host (default: /sys/fs/bpf/vxlan-tracer)
#
# What is removed:
#   - TC BPF filter at priority 1 on UNDERLAY ingress (tc_ingress_count_ptb)
#   - TC BPF filter at priority 1 on OVERLAY egress (tc_egress_track_flow)
#   - Pinned maps under PIN_DIR:
#       ptb_ingress_total, ptb_ingress_counts, icmp_rcv_total,
#       flow_state, frag_events_total
#
# What is NOT removed:
#   - The clsact qdisc (empty qdiscs cause no traffic impact; left for
#     the next run to reuse without an extra syscall)
#   - Network namespaces (use scripts/teardown-netns.sh)
#   - Kprobe links (owned by the Go process; auto-removed when it exits)

set -uo pipefail

NETNS="${NETNS:-ns1}"
OVERLAY="${OVERLAY:-vxlan0}"
UNDERLAY="${UNDERLAY:-veth1}"
PIN_DIR="${PIN_DIR:-/sys/fs/bpf/vxlan-tracer}"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "ERROR: This script requires Linux." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

ERRORS=0

# _tc_del removes TC filters at priority 1 from the given interface/direction.
# Silently succeeds when the namespace, interface, or filter is absent.
_tc_del() {
    local netns="$1" dev="$2" dir="$3"
    if ! ip netns list 2>/dev/null | grep -qw "^${netns}\( \|$\)"; then
        echo "[cleanup] netns $netns not found; skipping TC cleanup for $dev $dir"
        return 0
    fi
    if ! ip netns exec "$netns" ip link show "$dev" >/dev/null 2>&1; then
        echo "[cleanup] $netns/$dev not found; skipping TC filter cleanup for $dir"
        return 0
    fi
    if ip netns exec "$netns" tc filter del dev "$dev" "$dir" prio 1 2>/dev/null; then
        echo "[cleanup] removed TC filter: $netns/$dev $dir prio 1"
    else
        echo "[cleanup] no TC filter at $netns/$dev $dir prio 1 (ok)"
    fi
}

echo "[cleanup] TC filter cleanup (netns=$NETNS, underlay=$UNDERLAY, overlay=$OVERLAY)"
_tc_del "$NETNS" "$UNDERLAY" ingress
_tc_del "$NETNS" "$OVERLAY"  egress

echo "[cleanup] Pinned map cleanup (pin_dir=$PIN_DIR)"
for MAP in ptb_ingress_total ptb_ingress_counts icmp_rcv_total flow_state frag_events_total; do
    TARGET="${PIN_DIR}/${MAP}"
    if [[ -e "$TARGET" ]]; then
        if rm -f "$TARGET"; then
            echo "[cleanup] removed $TARGET"
        else
            echo "[cleanup] ERROR: could not remove $TARGET" >&2
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "[cleanup] $TARGET not found (ok)"
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    echo "[cleanup] Finished with $ERRORS error(s)." >&2
    exit 1
fi

echo "[cleanup] Done. All artefacts removed (or were already absent)."
exit 0
