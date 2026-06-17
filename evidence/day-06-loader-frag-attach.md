# Day 6: Go loader — ip_do_fragment kprobe attach (commit 3)

## What was changed

`internal/loader/loader.go`: added `FragKprobeObj string` to `Config`,
added `fragKprobeColl` and `fragKprobeLink` to `Attachment`, extended
`pinnedMaps` with `"fragkprobe": {"frag_events_total"}`, added the load-
pin-attach sequence for `frag_kprobes.bpf.o` / `kprobe_ip_do_fragment` /
`ip_do_fragment` immediately after the `icmp_rcv` kprobe attach. Updated
`Close()` to detach and close the new link and collection first.

`internal/loader/loader_other.go`: added `FragKprobeObj string` field to
the non-Linux stub Config to keep `go build ./...` working on macOS.

`cmd/vxlan-tracer/main.go`: passes
`FragKprobeObj: filepath.Join(*bpfDir, "frag_kprobes.bpf.o")` in the
`loader.Config` literal; updated the attach-success and detach messages
to say "kprobe/ip_do_fragment" and "kprobes" (plural).

## Test run (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

```
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 \
  --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs \
  --duration 10s
```

No traffic was sent (attach-only test). Raw log: `/tmp/d6-commit3-attach-test.log`.

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
No PTBs or oversized traffic were observed during this run, but the overlay MTU (1450) exceeds the safe value for the underlay MTU (1400) by 100 byte(s). This is a static configuration risk...
```

Exit code 0.

## TC filter confirmation

```
veth1 ingress:  tc_ingress_eth0  id 337  jited
vxlan0 egress:  tc_egress_vxlan0 id 338  jited
```

## Pinned maps after attach

```
/sys/fs/bpf/vxlan-tracer/flow_state
/sys/fs/bpf/vxlan-tracer/frag_events_total    ← new
/sys/fs/bpf/vxlan-tracer/icmp_rcv_total
/sys/fs/bpf/vxlan-tracer/ptb_ingress_counts
/sys/fs/bpf/vxlan-tracer/ptb_ingress_total
```

All five maps are pinned. `frag_events_total` was created and pinned by the
new loader path without error.

## Verdict explanation

The verdict is `VXLAN_MTU_MISCONFIGURATION` because no traffic was sent
(frag_events_total.total = 0, flow_state is empty) and the static MTU
check catches the stale overlay MTU (1450 > safe 1350). This is correct
for the no-traffic case — `VXLAN_FRAGMENTATION_OBSERVED` will appear once
large traffic is sent (commits 5-6, after the fragmentation verdict is
wired in commit 8).

## What is proven

- `ip_do_fragment` kprobe attaches via `link.Kprobe("ip_do_fragment", ...)`
  using cilium/ebpf — confirming the symbol is probbable on this kernel.
- `frag_events_total` is pinned and readable; the Go binary opened it,
  read key 0 (returned total=0, as expected with no traffic), and used it
  in the diagnosis without error.
- `Close()` detaches both kprobes cleanly (exit 0, no "detach error" line).
- The loader now attaches four hooks: TC ingress, TC egress, icmp_rcv
  kprobe, ip_do_fragment kprobe. All four survive the 10s window.

## What remains unproven

- `frag_events_total.total` has not yet been shown to increment (that is
  commits 5-6: small traffic → 0, large traffic → > 0).
- The `VXLAN_FRAGMENTATION_OBSERVED` verdict has not yet been printed
  (verdict logic update is commit 8).
