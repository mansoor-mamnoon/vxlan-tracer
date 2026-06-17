# Day 7: fragmentation scoping and frag_max_skb_len (commits 4–5)

## frag_max_skb_len in JSON output (commit 4)

`frag_events_total.max_skb_len` (set by the CO-RE BPF kprobe reading `skb->len`
at ip_do_fragment entry) is now surfaced in:
- `diag.Observation.FragMaxSKBLen uint32`
- JSON field: `frag_max_skb_len` (omitted when 0 / no fragmentation observed)

## Attempt to scope ip_do_fragment to VXLAN traffic

ip_do_fragment is a global kernel function — it fires for ALL outgoing IP
fragmentation on the host, not only VXLAN outer packets. For the lab
(single-purpose container with only VXLAN traffic), this is equivalent. In
production, other fragmented traffic could inflate the counter.

### Considered approach: ifindex scoping

Add a config BPF map with the underlay interface ifindex. In the kprobe, read
`skb->dev->ifindex` and count only when it matches. The problem: ifindex is
per network namespace and recycled. In a fresh Linux namespace:

  ns1: lo=1, veth1=2, vxlan0=3
  ns2: lo=1, veth2=2, vxlan0=3

Both veth1 (ns1) and veth2 (ns2) have ifindex=2. The kprobe fires globally, so
events from ns2's fragmentation (reply path) would match the configured
underlay_ifindex=2, producing incorrect scoping. Ifindex scoping across
namespaces is unreliable and is deferred to Day 8 (namespace ID comparison via
BPF netns helpers or per-device filtering).

### Implemented fallback: two-signal corroboration (commit 5)

`Diagnose()` now requires BOTH signals for the corroborated verdict:
1. `FragEventsTotal > 0` — ip_do_fragment kprobe fired
2. `MaxOuterIPLen > UnderlayMTU` — TC egress hook saw oversized VXLAN outer packet

If both signals are present: "Fragmentation was observed while oversized VXLAN
traffic was present — these two signals together are consistent with VXLAN outer
packets triggering ip_do_fragment."

If only FragEventsTotal > 0 (no MaxOuterIPLen confirmation): "Note: ip_do_fragment
is a global kernel function — the counter fires for ALL outgoing IP fragmentation
on this host, not only VXLAN outer packets. ... treat this as a weak indicator."

## Test run (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

### Run A — corroborated (both signals)

3 large pings (payload 1360B, inner IP 1388B, outer IP 1438B > 1400 underlay MTU):

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present ...",
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

Verdict: `VXLAN_FRAGMENTATION_OBSERVED` (corroborated).

### Run D — conservative (frag events but max_outer_ip_len < underlay MTU)

Same traffic (3 large pings) but in the fourth binary invocation. The kernel
route MTU cache, populated by prior fragmentation events, may reduce effective
packet sizes. Result:

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached. Note: ip_do_fragment is a global kernel function ...",
  "frag_events_total": 6,
  "frag_max_skb_len": 1388,
  "max_outer_ip_len": 1398
}
```

`max_outer_ip_len=1398 < underlay_mtu=1400` → corroboration condition not met →
conservative verdict fires. The message correctly disclaims global scope.

`frag_max_skb_len=1388` in Run D vs `1438` in Run A: the skb->len value at
ip_do_fragment entry may differ based on kernel-internal state (route cache,
PMTU, sk_buff headroom). `1388` matches the inner IP length; `1438` matches the
outer IP length. Both are valid kernel-dependent readings of `skb->len` at
different points in the same code path; the interpretation depends on VXLAN
driver internals at the specific kernel version.

## What is proven

- `frag_max_skb_len` is now present in JSON output when fragmentation occurs.
- In Run A: `frag_max_skb_len=1438` (matches outer IP length).
- In Run D: `frag_max_skb_len=1388` (matches inner IP length; kernel-dependent).
- The two-signal corroboration gate correctly prevents a false "corroborated"
  verdict when TC egress data doesn't confirm oversized VXLAN traffic.
- The conservative verdict message correctly notes global scope.
- 12 unit tests (11 original + 1 new `TestDiagnoseFragmentationObservedGlobalOnly`): all pass.

## What remains unproven

- VXLAN-specific ifindex scoping of ip_do_fragment events (deferred; see above).
- Whether `frag_max_skb_len` reliably reports the outer IP length vs inner IP
  length across kernel versions. The value is kernel-dependent.
- Whether the Route MTU cache effect (reduced max_outer_ip_len after repeated
  fragmentation) can be worked around to produce consistent corroborated verdicts
  across sequential runs.
