# Day 7: cleanup script idempotency (commit 1)

## Goal

Add `scripts/cleanup-bpf.sh` to remove TC filters and pinned maps. The script
must be idempotent: running it twice without any artefacts to clean should exit 0.

## What the script removes

- TC BPF filter at priority 1 on `UNDERLAY ingress` (tc_ingress_count_ptb)
- TC BPF filter at priority 1 on `OVERLAY egress` (tc_egress_track_flow)
- Pinned BPF maps: ptb_ingress_total, ptb_ingress_counts, icmp_rcv_total,
  flow_state, frag_events_total

What it does NOT remove: clsact qdisc (left in place; empty qdisc has no
traffic impact), network namespaces, kprobe links (process-owned).

## Test run (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

### Test 1A — cleanup with no artefacts (first call)

```
[cleanup] TC filter cleanup (netns=ns1, underlay=veth1, overlay=vxlan0)
[cleanup] no TC filter at ns1/veth1 ingress prio 1 (ok)
[cleanup] no TC filter at ns1/vxlan0 egress prio 1 (ok)
[cleanup] Pinned map cleanup (pin_dir=/sys/fs/bpf/vxlan-tracer)
[cleanup] /sys/fs/bpf/vxlan-tracer/ptb_ingress_total not found (ok)
[cleanup] /sys/fs/bpf/vxlan-tracer/ptb_ingress_counts not found (ok)
[cleanup] /sys/fs/bpf/vxlan-tracer/icmp_rcv_total not found (ok)
[cleanup] /sys/fs/bpf/vxlan-tracer/flow_state not found (ok)
[cleanup] /sys/fs/bpf/vxlan-tracer/frag_events_total not found (ok)
[cleanup] Done. All artefacts removed (or were already absent).
Exit: 0
```

### Test 1B — second call immediately after (still no artefacts)

Identical output. Exit: 0.

### Test 4 — cleanup after binary has run (artefacts present)

After running the binary twice, TC filters are on both interfaces and all
5 maps are pinned:

```
[cleanup] TC filter cleanup (netns=ns1, underlay=veth1, overlay=vxlan0)
[cleanup] removed TC filter: ns1/veth1 ingress prio 1
[cleanup] removed TC filter: ns1/vxlan0 egress prio 1
[cleanup] Pinned map cleanup (pin_dir=/sys/fs/bpf/vxlan-tracer)
[cleanup] removed /sys/fs/bpf/vxlan-tracer/ptb_ingress_total
[cleanup] removed /sys/fs/bpf/vxlan-tracer/ptb_ingress_counts
[cleanup] removed /sys/fs/bpf/vxlan-tracer/icmp_rcv_total
[cleanup] removed /sys/fs/bpf/vxlan-tracer/flow_state
[cleanup] removed /sys/fs/bpf/vxlan-tracer/frag_events_total
[cleanup] Done. All artefacts removed (or were already absent).
Exit: 0
```

After cleanup: `tc filter show dev veth1 ingress` → empty (no output).
`tc filter show dev vxlan0 egress` → empty (no output).
PIN_DIR is empty (maps removed; directory remains).

### Test 5 — cleanup after first cleanup (re-idempotency)

Same as Test 1A output. Exit: 0.

## What is proven

- Script exits 0 whether artefacts exist or not.
- Script correctly removes TC filters at priority 1 from both interfaces.
- Script correctly removes all 5 pinned maps.
- Idempotency: calling twice produces identical exit code (0) both times.

## What remains unproven

- Behavior when NETNS doesn't exist (would print the "not found" message and skip).
- Behavior when the cleanup script is run from INSIDE the network namespace
  (currently designed for host-level invocation).
- Interaction with TC filters added by other tools at different priorities.
