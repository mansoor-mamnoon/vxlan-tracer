#!/usr/bin/env bash
# scripts/diagnose-from-bpftool.sh
#
# SPIKE / LAB TOOL — reads live BPF map values via bpftool and prints a
# suppression verdict. Requires Linux, root, and bpftool on PATH or at
# BPFTOOL env var.
#
# Usage:
#   sudo BPFTOOL=/usr/lib/linux-tools-5.15.0-181/bpftool \
#     bash scripts/diagnose-from-bpftool.sh
#
# The script finds the relevant maps by name (ptb_ingress_tot and
# icmp_rcv_total) in bpftool map list output, reads their values, and
# prints one of three verdicts:
#
#   PTB SUPPRESSED BEFORE icmp_rcv
#       ptb_ingress_total > 0 AND icmp_rcv_total == 0
#       → PTBs arrived at the underlay interface but were dropped by
#         netfilter (iptables/nft) before icmp_rcv. This is the suppression
#         signal that causes VXLAN MTU blackholes to be invisible to the stack.
#
#   PTB DELIVERED (not suppressed)
#       ptb_ingress_total > 0 AND icmp_rcv_total > 0
#       → PTBs arrived and reached icmp_rcv. The MTU hint was delivered.
#
#   NO PTBs OBSERVED
#       ptb_ingress_total == 0
#       → TC ingress BPF saw no ICMP PTBs. Either there is no MTU event,
#         the TC program is not attached, or PTBs are arriving on a different
#         interface.
#
# Note: this is a lab combiner for evidence, not the final CLI. It reads
# current map values; it does not track deltas over time.

set -euo pipefail

BPFTOOL="${BPFTOOL:-bpftool}"

if ! command -v "$BPFTOOL" >/dev/null 2>&1; then
    echo "ERROR: bpftool not found. Set BPFTOOL env var to the full path." >&2
    echo "       Example: BPFTOOL=/usr/lib/linux-tools-5.15.0-181/bpftool" >&2
    exit 1
fi

# Find map IDs by name
PTB_TOT_ID=$("$BPFTOOL" map list 2>/dev/null \
    | awk '/ptb_ingress_tot/{print $1}' | tr -d ':' | tail -1)
ICMP_RCV_ID=$("$BPFTOOL" map list 2>/dev/null \
    | awk '/icmp_rcv_total/{print $1}' | tr -d ':' | tail -1)
PTB_CNT_ID=$("$BPFTOOL" map list 2>/dev/null \
    | awk '/ptb_ingress_cou/{print $1}' | tr -d ':' | tail -1)
FLOW_ID=$("$BPFTOOL" map list 2>/dev/null \
    | awk '/flow_state/{print $1}' | tr -d ':' | tail -1)

echo "=== vxlan-tracer diagnosis ==="
echo ""

if [ -z "$PTB_TOT_ID" ]; then
    echo "ERROR: ptb_ingress_total map not found in bpftool map list."
    echo "       Ensure tc_ingress_eth0 is attached to the underlay interface:"
    echo "         tc qdisc add dev <underlay> clsact"
    echo "         tc filter add dev <underlay> ingress bpf da obj tc_ingress_eth0.bpf.o sec tc"
    exit 1
fi

if [ -z "$ICMP_RCV_ID" ]; then
    echo "ERROR: icmp_rcv_total map not found."
    echo "       Ensure probe_attach is running with kprobes.bpf.o."
    exit 1
fi

# Read map values
PTB_TOTAL=$("$BPFTOOL" map dump id "$PTB_TOT_ID" 2>/dev/null \
    | grep -oE '"value": [0-9]+' | grep -oE '[0-9]+' || echo 0)
ICMP_RCV=$("$BPFTOOL" map dump id "$ICMP_RCV_ID" 2>/dev/null \
    | grep -oE '"value": [0-9]+' | grep -oE '[0-9]+' || echo 0)

echo "Maps:"
echo "  ptb_ingress_total (map $PTB_TOT_ID, TC ingress pre-netfilter) = $PTB_TOTAL"
echo "  icmp_rcv_total    (map $ICMP_RCV_ID, kprobe post-netfilter)   = $ICMP_RCV"

if [ -n "$FLOW_ID" ]; then
    FLOW_COUNT=$("$BPFTOOL" map dump id "$FLOW_ID" 2>/dev/null \
        | grep -c '"key"' || echo 0)
    echo "  flow_state        (map $FLOW_ID, vxlan0 egress overlay flows)  = $FLOW_COUNT entries"
fi
if [ -n "$PTB_CNT_ID" ]; then
    PTB_PAIRS=$("$BPFTOOL" map dump id "$PTB_CNT_ID" 2>/dev/null \
        | grep -c '"key"' || echo 0)
    echo "  ptb_ingress_counts (map $PTB_CNT_ID, per VTEP pair)           = $PTB_PAIRS pairs"
fi

echo ""

# Verdict
if [ "$PTB_TOTAL" -eq 0 ]; then
    echo "VERDICT: NO PTBs OBSERVED"
    echo "  TC ingress BPF counted zero ICMP fragmentation-needed packets."
    echo "  Either there is no MTU event, the TC program is not attached to"
    echo "  the correct interface, or PTBs are arriving on a different interface."
elif [ "$ICMP_RCV" -eq 0 ]; then
    SUPPRESSED=$((PTB_TOTAL - ICMP_RCV))
    echo "VERDICT: PTB SUPPRESSED BEFORE icmp_rcv"
    echo "  ptb_ingress_total = $PTB_TOTAL  (arrived before netfilter)"
    echo "  icmp_rcv_total    = $ICMP_RCV   (reached icmp_rcv)"
    echo "  suppressed count  = $SUPPRESSED"
    echo ""
    echo "  PTBs arrived at the underlay interface (TC ingress counted them)"
    echo "  but were dropped by netfilter INPUT before icmp_rcv was called."
    echo "  Likely cause: iptables/nft rule dropping ICMP type 3 code 4."
    echo "  Effect: kernel does not update PMTU cache; VXLAN MTU blackhole"
    echo "  persists silently."
    echo ""
    echo "  To confirm: ip netns exec <ns> iptables -L INPUT -v -n"
    echo "              ip netns exec <ns> nft list ruleset"
else
    echo "VERDICT: PTB DELIVERED (not suppressed)"
    echo "  ptb_ingress_total = $PTB_TOTAL  (arrived before netfilter)"
    echo "  icmp_rcv_total    = $ICMP_RCV   (reached icmp_rcv)"
    echo ""
    echo "  PTBs arrived and reached icmp_rcv. The MTU hint was delivered"
    echo "  to the kernel PMTU cache. No PTB suppression detected."
fi
