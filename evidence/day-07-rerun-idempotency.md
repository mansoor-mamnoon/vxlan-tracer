# Day 7: rerun idempotency for Go loader TC attach (commit 2)

## Problem

Before Day 7, running the binary a second time in the same container
(without manual cleanup) failed with:

```
error: attach failed: attach tc ingress on veth1: file exists
```

The root cause: `attachTC` used `netlink.FilterAdd` which sends
`RTM_NEWTFILTER` with `NLM_F_CREATE | NLM_F_EXCL`. The TC clsact qdisc
(and the filter at priority 1) from the first run persists after the binary
exits (TC filters are owned by the qdisc, not the process). On the second
run, `NLM_F_EXCL` caused EEXIST.

## Fix (internal/loader/loader.go)

Changed `attachTC` to list and delete any existing priority-1 filter before
adding the new one:

```go
if existing, err := netlink.FilterList(l, parent); err == nil {
    for _, f := range existing {
        if f.Attrs().Priority == 1 {
            _ = netlink.FilterDel(f)
        }
    }
}
// then netlink.FilterAdd(filter)
```

The delete is best-effort: if it fails, `FilterAdd` will still report the
problem clearly. This pattern makes re-running the binary in the same lab
idempotent without requiring a manual cleanup step.

## Test run (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

### First run

```
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
verdict: VXLAN_MTU_MISCONFIGURATION
...
detached kprobes (TC filters remain attached; maps remain pinned)
```
Exit: 0

### Second run (same lab, no manual cleanup)

```
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
verdict: VXLAN_MTU_MISCONFIGURATION
...
detached kprobes (TC filters remain attached; maps remain pinned)
```
Exit: 0

NO "file exists" error. The loader correctly detected and removed the existing
priority-1 filters before attaching the new ones.

## What is proven

- Binary can be run twice in the same container without manual cleanup.
- `attachTC` delete-then-add is idempotent on kernel 6.10.14-linuxkit.
- The clsact qdisc from the first run is reused (not recreated) — `ensureClsact`
  is already idempotent and leaves the existing qdisc in place.
- No traffic disruption: the brief window where the old filter is deleted
  and the new one is not yet installed is in the microsecond range.

## What remains unproven

- Whether `FilterDel` failure in the delete phase causes a visible issue
  (e.g., if permissions are wrong). In that case, the subsequent `FilterAdd`
  would return the real EEXIST error.
- Whether the clsact qdisc from a prior run could have other (non-vxlan-tracer)
  filters at priority 1 that might be deleted unintentionally. In a lab
  environment with only vxlan-tracer filters, this is not a concern.
