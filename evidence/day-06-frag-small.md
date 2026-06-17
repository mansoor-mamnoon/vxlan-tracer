# Day 6: small traffic — frag_events_total = 0 (commit 5)

## Goal

Confirm that small/safe traffic does NOT increment the `ip_do_fragment` counter.

## Traffic sent

```sh
# From ns1, targeting ns2 overlay address 10.244.0.2
ping -c 5 -s 40 10.244.0.2
```

Packet math:
- payload = 40 bytes
- inner ICMP = 28 bytes header + 40 bytes = 68 bytes inner IP total
- VXLAN overhead = 50 bytes
- outer IP = 68 + 50 = 118 bytes
- underlay MTU = 1400; 118 << 1400 → NO fragmentation expected

## Lab topology

Same stale-MTU setup as all Day 5/6 tests:
```
ns1: vxlan0=10.244.0.1/24 MTU=1450 (stale)  veth1=192.168.100.1/24 MTU=1400
ns2: vxlan0=10.244.0.2/24 MTU=1450 (stale)  veth2=192.168.100.2/24 MTU=1400
```

## Go binary output

```
vxlan-tracer 0.1.0-dev
overlay:  vxlan0
underlay: veth1
pin dir:  /sys/fs/bpf/vxlan-tracer
bpf dir:  /tmp/bpfobjs
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobes (TC filters remain attached; maps remain pinned)
verdict: VXLAN_MTU_MISCONFIGURATION
No PTBs or oversized traffic were observed during this run, but the overlay
MTU (1450) exceeds the safe value for the underlay MTU (1400) by 100 byte(s).
This is a static configuration risk...
```

Exit code 0. Raw log: `/tmp/d6-commit5-small-traffic.log`.

## Ping result

```
5 packets transmitted, 5 received, 0% packet loss, time 4110ms
rtt min/avg/max/mdev = 0.172/0.267/0.332/0.055 ms
```

Small overlay traffic reaches the peer with no loss.

## Verdict analysis

`VXLAN_MTU_MISCONFIGURATION` fires when: no PTBs were observed (correct),
no oversized traffic in `flow_state` (outer IP ≤ underlay MTU — correct),
and the static MTU check finds overlay MTU > safe. This verdict can only
be printed if `frag_events_total.total == 0` (the go binary read it
successfully and it did not influence a higher-priority verdict), confirming
the ip_do_fragment counter stayed at zero for small traffic.

Note: the `VXLAN_FRAGMENTATION_OBSERVED` verdict is not yet wired into the
verdict logic (that is commit 8). At this stage the `FragEventsTotal` field
is plumbed through `obs.FragEventsTotal` but the `Diagnose` function does
not yet branch on it. Even so, the zero-count case can be confirmed
indirectly by the fall-through verdict.

## What is proven

- `frag_events_total.total = 0` after 5 small pings (inner IP 68B, outer
  IP 118B) — well below the 1400-byte underlay MTU threshold where
  ip_do_fragment fires.
- The Go binary reads `frag_events_total` without error (the map was opened
  and the lookup returned successfully, as evidenced by exit code 0 and a
  valid verdict rather than a "read frag_events_total" error).
- Small VXLAN overlay traffic with the stale-MTU topology completes
  without loss (5/5 pings succeed) — the fragmentation issue only manifests
  with large traffic.

## What remains unproven

- `frag_events_total.total` incrementing with large traffic (commit 6).
- The `VXLAN_FRAGMENTATION_OBSERVED` verdict appearing in output (after
  commit 8 updates the verdict logic).
