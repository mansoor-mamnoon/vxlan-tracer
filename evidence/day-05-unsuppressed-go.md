# Day 5: unsuppressed PTB test through the Go CLI (commit 8)

This is the first end-to-end run where the Go binary itself — not a shell
script reading bpftool output — attaches, observes, reads its own pinned
maps, and prints the diagnosis verdict.

## What changed to make this possible

- `internal/loader.Attachment` gained an `MTUs()` method that re-reads the
  overlay/underlay interface MTUs at call time via netlink (not cached from
  attach time), so the diagnosis sees the current configuration.
- `cmd/vxlan-tracer/main.go` now opens the pinned maps via
  `bpfmap.OpenPinned`, reads `ptb_ingress_total`, `icmp_rcv_total`, and the
  largest `max_outer_ip_len` across `flow_state`, builds a
  `diag.Observation`, calls `diag.Diagnose`, and prints the resulting
  verdict and message to stdout before exiting.

## Test setup

Same ns1/ns2/vxlan0 lab as every prior day (`scripts/setup-netns.sh`):
underlay MTU 1400, overlay (vxlan0) MTU stale at 1450. No iptables rule was
added in ns1 — confirmed via `iptables -L INPUT -v -n` showing an empty,
default-ACCEPT INPUT chain immediately before injection.

Sequence:
1. `nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 --overlay
   vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer --bpf-dir
   /tmp/bpfobjs --duration 20s` started in the background.
2. After a 3s settle, confirmed attach succeeded
   (`attached: tc ingress, tc egress, kprobe/icmp_rcv; maps pinned under
   /sys/fs/bpf/vxlan-tracer`) and confirmed the empty iptables INPUT chain.
3. From ns2: `python3 spikes/inject_ptb.py --src 192.168.100.2 --dst
   192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5` — sent 5
   synthetic ICMP type=3/code=4 packets toward ns1's underlay.
4. Waited for the Go process to finish its full `--duration 20s` window.

## Result

```
attached: tc ingress, tc egress, kprobe/icmp_rcv; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobe (TC filters remain attached; maps remain pinned)
verdict: PTB_DELIVERED
5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.
```

Exit code 0. The 5/5 counts read by the Go binary's own `bpfmap.OpenPinned`
reader match exactly the 5 PTBs injected — this is the loader, the kprobe
filter (Day 5 commit 1), the pinned-map reader (commit 6), and the verdict
logic (commit 7) all working together against a live kernel, with no
bpftool or shell intermediary.

Raw log: `/tmp/day5-commit8-unsuppressed.log` (Docker run, exit code 0).

## What is proven

- The full Go-driven path — attach, observe live traffic, read pinned maps,
  diagnose, print a verdict, detach — works end to end against a real
  kernel for the case where PTBs are NOT suppressed.
- `PTB_DELIVERED` is the correct verdict when ingress and icmp_rcv counts
  match (both 5): this is the "not suppressed" case from the Day 5 success
  condition.

## What remains unproven

- The suppressed case (iptables DROP rule present, expecting
  `PTB_SUPPRESSED` with icmp_rcv staying at 0) has not yet been run through
  this same Go path — that is commit 9.
- `VXLAN_FRAGMENTATION_RISK` and `VXLAN_MTU_MISCONFIGURATION` verdicts are
  only unit-tested (commit 7); no live run in this lab has exercised the
  no-PTB-observed branches of `Diagnose` end-to-end, since this lab's
  default traffic pattern (small pings) doesn't generate oversized flows
  without deliberately running a large-payload smoke test.
- `bpftool` was not present in this container, so the pinned-map cross-check
  against a second, independent reading tool was skipped; the only reader
  exercised was the Go binary's own `bpfmap.OpenPinned`.
