# evidence/day-16-human-output-live.md

Live printHuman output captured from CI runs.

---

## VXLAN_FRAGMENTATION_OBSERVED (confirmed)

**CI run:** 27860935585 ("x86_64 validation suite"), 2026-06-20T05:04Z
**Runner:** ubuntu-22.04, kernel 6.8.0-1059-azure, x86_64
**Job:** Human-readable output validation — VXLAN_FRAGMENTATION_OBSERVED step
**Validation:** [PASS] contains Verdict: / [PASS] contains Evidence: / [PASS] verdict present

Setup: netns with vxlan0 (overlay, VNI 77) and ho-veth1 (underlay MTU 1400). Overlay MTU
auto-set to ~1450 by kernel. Sent 3 pings of 1360 bytes (outer 1438B > underlay 1400B).

Actual binary output:

```
vxlan-tracer dev
overlay:    vxlan0
underlay:   ho-veth1
vxlan port: 4789 (auto-detected)
vxlan vni:  77
pin dir:    /sys/fs/bpf/ho-test
bpf dir:    bpf
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/ho-test
maps cleared: fresh baseline for this run
detached kprobes (TC filters remain attached; maps remain pinned)

Verdict:  VXLAN_FRAGMENTATION_OBSERVED
Evidence:
  ip_do_fragment events:   3
  largest outer IP seen:   1438 B
  underlay MTU:            1400 B  (outer packet exceeded by 38 B)
Recommendation:
  set overlay MTU to 1350 B or lower
  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)
Scope:
  global fragmentation counter corroborated by VXLAN TC egress
  (both ip_do_fragment and oversized outer packets observed)
  See docs/fragmentation-scoping.md for limitations.
```

Verdict: VXLAN_FRAGMENTATION_OBSERVED ✓
Scope: global_corroborated ✓
ip_do_fragment events: 3 (3 pings × 1 fragment each) ✓
largest outer IP: 1438 B ✓
underlay MTU: 1400 B ✓

---

## PTB_SUPPRESSED (confirmed)

**CI run:** 27860935585 ("x86_64 validation suite"), 2026-06-20T05:05Z
**Runner:** ubuntu-22.04, kernel 6.8.0-1059-azure, x86_64
**Job:** Human-readable output validation — PTB_SUPPRESSED step
**Validation:** [PASS] contains Verdict: / [PASS] verdict present

Setup: two-netns VXLAN topology via scripts/setup-netns.sh (ns1: vxlan0 + veth1 MTU 1400;
ns2: veth2 injector). iptables DROP rule in ns1 for ICMP type 3/4. Binary ran inside ns1
for 10s. inject_ptb.py sent 5 synthetic PTBs from ns2 via veth2.

Actual binary output:

```
vxlan-tracer dev
overlay:    vxlan0
underlay:   veth1
vxlan port: 4789
pin dir:    /sys/fs/bpf/ho-ptb-test
bpf dir:    bpf
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/ho-ptb-test
maps cleared: fresh baseline for this run
detached kprobes (TC filters remain attached; maps remain pinned)

Verdict:  PTB_SUPPRESSED
Evidence:
  PTBs at TC ingress (pre-netfilter): 5
  PTBs at icmp_rcv  (post-netfilter): 0  ← dropped before kernel
Recommendation:
  PTBs are being dropped between the NIC and icmp_rcv.
  Check:  iptables/nftables INPUT chain for ICMP type 3 code 4 DROP rules.
  Fix:    allow ICMP fragmentation-needed (type 3 code 4) through your firewall.
```

Verdict: PTB_SUPPRESSED ✓
PTBs at TC ingress: 5 (5 synthetic PTBs injected) ✓
PTBs at icmp_rcv: 0 (iptables DROP active in ns1) ✓

---

## What is proven (as of this file)

- `Verdict:`, `Evidence:`, `Recommendation:`, `Scope:` sections present for
  VXLAN_FRAGMENTATION_OBSERVED (CI run 27860935585, PASS)
- `global_corroborated` scope confirmed (both ip_do_fragment and TC egress observed)
- Binary loads correctly with bpffs pin dir present
- PTB_SUPPRESSED: `Verdict:` and `Evidence:` sections present (CI run 27860935585, PASS)
  - TC ingress count correctly captures pre-netfilter PTBs
  - icmp_rcv count correctly shows 0 (iptables DROP blocks delivery)

## What is not captured live

- PTB_DELIVERED actual output (not separately captured via CI; scenario 3 runs in
  bpf-scenario job but only summary verdicts are logged, not full printHuman blocks)
- VXLAN_MTU_MISCONFIGURATION actual output (not separately captured)
- NO_ISSUE_OBSERVED actual output (not currently tested in CI)
