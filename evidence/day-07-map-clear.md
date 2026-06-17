# Day 7: map counter clearing (commit 3)

## Problem

Before Day 7, pinned BPF map counters accumulated across binary restarts. A run
that observed 5 PTBs would leave `ptb_ingress_total=5` in the pinned map. A
subsequent run with zero traffic would read 5 and diagnose PTB_SUPPRESSED
incorrectly.

## Fix

Added `bpfmap.ClearPinned(pinDir)` which:
- Zeros ARRAY maps at key 0: `ptb_ingress_total`, `icmp_rcv_total`, `frag_events_total`
- Flushes HASH maps by collecting all keys then deleting each:
  `ptb_ingress_counts`, `flow_state`

Called in `main()` immediately after `loader.Attach()`, before entering the
observation window. A `--no-clear` flag skips clearing (useful for debugging
or accumulating across runs).

## Test run (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

### Run A: large traffic produces frag_events_total=6

```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer --duration 20s --json &
# 3s wait, then:
ip netns exec ns1 ping -c 3 -s 1360 10.244.0.2
```

Stderr: `maps cleared: fresh baseline for this run`
JSON: `"frag_events_total":6,"max_outer_ip_len":1438`
Verdict: `VXLAN_FRAGMENTATION_OBSERVED`

### Run B: --no-clear shows stale counters from Run A

```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer --duration 5s --json --no-clear
# no traffic
```

Stderr: `maps NOT cleared (--no-clear): counters may include prior-run data`
JSON: `"frag_events_total":6,"max_outer_ip_len":1438` (stale values from Run A)
Verdict: `VXLAN_FRAGMENTATION_OBSERVED` (stale; shows the old problem)

### Run C: default clear — counters reset, no false verdict

```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer --duration 5s --json
# no traffic
```

Stderr: `maps cleared: fresh baseline for this run`
JSON: `"frag_events_total":0,"max_outer_ip_len":0`
Verdict: `VXLAN_MTU_MISCONFIGURATION` (correct — no traffic observed this run)
Exit: 0

## What is proven

- ClearPinned resets ARRAY counters (frag_events_total=6 → 0 between Run A and Run C).
- ClearPinned flushes HASH map entries (max_outer_ip_len=1438 → 0 between Run A and Run C).
- Without clear (Run B), stale counters from a prior run produce a misleading verdict.
- With clear (Run C), the second run correctly reflects only the current observation window.
- The `--no-clear` flag is useful for debugging but must be used carefully.

## What remains unproven

- Whether ClearPinned correctly handles a map that is concurrently being written by
  the BPF program. Race between ClearPinned and the BPF kprobe is theoretically
  possible but benign for a diagnostic tool.
- Whether ptb_ingress_counts HASH map flush correctly handles >4096 entries
  (max_entries=4096; the flush deletes all entries collected in one pass).
