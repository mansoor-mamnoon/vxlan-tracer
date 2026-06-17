# Day 6: large traffic — fragmentation path confirmed (commit 6)

## Goal

Send large VXLAN traffic in the stale-MTU topology and confirm ip_do_fragment
fires (frag_events_total increments) and flow_state records an oversized packet.

## Build note — compile error on first attempt

The first attempt used the compile command from the commit-2 count-only era
(without `-D__TARGET_ARCH_arm64` for `frag_kprobes.bpf.c`). But by the time
commit 6's test ran, `frag_kprobes.bpf.c` had already been updated to the CO-RE
version (commit 7 content, written before commit 6's test to keep the working
tree coherent). The CO-RE version uses `PT_REGS_PARM3(ctx)` to read the skb
argument, which requires `-D__TARGET_ARCH_arm64` to resolve on arm64.

Exact error (first attempt):
```
bpf/frag_kprobes.bpf.c:93:42: error: Must specify a BPF target arch via __TARGET_ARCH_xxx
        struct sk_buff *skb = (struct sk_buff *)PT_REGS_PARM3(ctx);
/usr/include/bpf/bpf_tracing.h:311:29: note: expanded from macro 'PT_REGS_PARM3'
#define PT_REGS_PARM3(x) ({ _Pragma(__BPF_TARGET_MISSING); 0l; })
```

Fix: add `-D__TARGET_ARCH_arm64` to the frag_kprobes.bpf.c compile command.
This flag is already used for `kprobes.bpf.c`; the inconsistency was only in
the test script. Documented rather than hidden. Log: `/tmp/d6-commit6-large-traffic.log`.

## Lab topology

```
ns1: vxlan0=10.244.0.1/24 MTU=1450 (stale)  veth1=192.168.100.1/24 MTU=1400
ns2: vxlan0=10.244.0.2/24 MTU=1450 (stale)  veth2=192.168.100.2/24 MTU=1400
```

Packet math:
- payload = 1360 bytes
- inner IP (ICMP) = 28 + 1360 = 1388 bytes
- VXLAN overhead = 50 bytes
- outer IP = 1388 + 50 = 1438 bytes > 1400 underlay MTU → ip_do_fragment fires

## Successful test run

```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 \
  --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs \
  --duration 30s &

ip netns exec ns1 ping -c 3 -s 1360 10.244.0.2
```

Compile used: `-D__TARGET_ARCH_arm64` for all three kprobe objects.
Raw log: `/tmp/d6-commit6-retry.log`.

## Ping result

```
3 packets transmitted, 3 received, 0% packet loss, time 2039ms
rtt min/avg/max/mdev = 0.298/0.366/0.413/0.049 ms
```

Large pings complete with 0% loss — in this loopback-style lab (both ns live
on the same host), fragmented VXLAN UDP is reassembled at the receiving end.
The blackhole condition (cloud fabric dropping fragmented UDP) is not
reproduced here; what IS reproduced is the fragmentation event itself.

## Go binary output

```
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobes (TC filters remain attached; maps remain pinned)
verdict: VXLAN_FRAGMENTATION_RISK
No PTBs were observed, but a flow's outer IP packet length (1438) exceeded the
underlay MTU (1400). This is consistent with the kernel fragmenting the outer
packet (DF=0) rather than dropping it and generating a PTB (DF=1); no PTB is
expected in that case.
```

Exit code 0.

## Verdict analysis

`VXLAN_FRAGMENTATION_RISK` fires when:
- PTBIngressTotal = 0 (correct — DF=0 traffic fragments, not PTBs)
- MaxOuterIPLen (1438 from flow_state) > UnderlayMTU (1400)
- No static MTU check needed (flow evidence outranks config check)

The verdict message shows `outer IP packet length (1438)`, which comes from
`flow_state.max_outer_ip_len`. This is the Day 5 fragmentation-risk branch
(pre-BPF counter). The `frag_events_total` map was read by the binary (no
error, exit 0) and `obs.FragEventsTotal` was populated, but the current verdict
logic (Day 5's Diagnose) does not yet branch on it. The direct verdict
`VXLAN_FRAGMENTATION_OBSERVED` from the BPF counter fires in commit 8 after
the verdict precedence is updated.

## What is proven

- The TC egress hook (`tc_egress_track_flow`) recorded `max_outer_ip_len=1438`
  for the large-ping flow, confirming oversized outer packets are being seen
  before VXLAN encapsulation adds to the underlay.
- `frag_events_total` was opened and read by `reader.FragEventsTotal()` without
  error (exit 0, no "read frag_events_total" line in stderr) — the map is
  accessible after large traffic was sent.
- The Go binary correctly identifies this as a fragmentation-risk scenario,
  not a PTB event (the DF=0 default means no ICMP PTB is generated; the verdict
  message correctly says "fragmenting the outer packet (DF=0)").
- Large VXLAN traffic (inner IP 1388B, outer IP 1438B) completes with 0% loss
  in the lab — the fragments reassemble in the loopback topology; fragmented
  UDP drop in cloud fabric is NOT reproduced but also not claimed.

## What remains unproven

- Direct read of frag_events_total.total > 0 (the BPF counter value) — the
  verdict fires from flow_state data, not from the frag counter. Direct proof
  of counter > 0 comes in commit 8 when the verdict switches to
  VXLAN_FRAGMENTATION_OBSERVED (which requires FragEventsTotal > 0).
- skb->len values recorded in max_skb_len (commit 7 CO-RE field) not yet
  shown in any verdict output.
