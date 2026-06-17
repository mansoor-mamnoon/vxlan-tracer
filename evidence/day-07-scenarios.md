# Day 7: automated scenario runner (commit 6)

## scripts/run-scenarios.sh

Four end-to-end scenarios that exercise every verdict path. Each scenario:
1. Runs `scripts/cleanup-bpf.sh` (idempotent; removes TC filters + pinned maps)
2. Calls `scripts/setup-netns.sh` (creates ns1/ns2 with MTU=1400 underlay)
3. Runs the binary with `--json` in a background nsenter
4. Sleeps 4 s, then triggers scenario-specific traffic/injection
5. Waits for the binary to exit, parses JSON verdict, asserts expected match

Exit code: 0 if all pass, 1 if any fail.

## Docker test (ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, 2026-06-13)

```
docker run --rm --privileged \
  -v /path/to/vxlan-tracer:/work \
  ubuntu:22.04 bash /tmp/d7-test-scenarios.sh
```

### Scenario 1: healthy_small → VXLAN_MTU_MISCONFIGURATION

Traffic: 5 pings, payload 40 B (inner IP 68 B, outer IP 118 B — well under 1400).

```json
{
  "verdict": "VXLAN_MTU_MISCONFIGURATION",
  "message": "No PTBs, fragmentation events, or oversized traffic were observed ...",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 118
}
```

Result: **PASS** (no active fault; static MTU misconfiguration detected from config alone)

### Scenario 2: fragmentation → VXLAN_FRAGMENTATION_OBSERVED

Traffic: 3 pings, payload 1360 B (inner IP 1388 B, outer IP 1438 B > 1400 underlay MTU).

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present ...",
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

Result: **PASS** (corroborated two-signal verdict: both ip_do_fragment kprobe and TC egress confirmed)

### Scenario 3: ptb_delivered → PTB_DELIVERED

Traffic: 5 synthetic ICMP type=3/code=4 injected via `spikes/inject_ptb.py` from ns2,
no iptables DROP rule active.

```json
{
  "verdict": "PTB_DELIVERED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0
}
```

Result: **PASS** (TC ingress count == icmp_rcv count; no suppression)

### Scenario 4: ptb_suppressed → PTB_SUPPRESSED

Traffic: 5 synthetic ICMP PTBs injected, with iptables DROP rule installed first:
`iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP`

```json
{
  "verdict": "PTB_SUPPRESSED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.",
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0
}
```

Result: **PASS** (TC ingress=5, icmp_rcv=0; suppression delta correctly detected)

## Final summary

```
Results: 4 passed, 0 failed
run-scenarios exit: 0
```

## What is proven

- All four verdict paths execute correctly in a single Docker container run.
- Each scenario performs idempotent cleanup before running — no manual teardown needed.
- The fragmentation scenario produces the corroborated two-signal verdict
  (`frag_max_skb_len=1438`, `max_outer_ip_len=1438`, both > underlay MTU 1400)
  consistently on a fresh cleanup between runs.
- PTB suppression detection works end-to-end: iptables DROP before netfilter
  vs. no DROP yields distinct `icmp_rcv_total` counts.
- Binary exit code is 0 for all four diagnostic outcomes (including adverse ones).
- Each run takes approximately 15 s (configurable via DURATION env var).

## What remains unproven

- The scenario runner has not been tested under concurrent load or when other
  network traffic is present on the host.
- The fragmentation scenario result (corroborated vs. conservative) may vary
  on kernels with aggressive route MTU caching; the runner checks only for
  the `VXLAN_FRAGMENTATION_OBSERVED` verdict string, not which sub-path fired.
- Runs on x86_64 or other architectures are not tested (only aarch64/arm64).
