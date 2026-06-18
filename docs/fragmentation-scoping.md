# ip_do_fragment scoping options

## Problem statement

`ip_do_fragment` is a global kernel function. The kprobe counter
`frag_events_total` fires for **all** outgoing IP fragmentation on the host,
not only VXLAN outer packet fragmentation. On a busy host running services
other than VXLAN, this counter will include non-VXLAN fragmentation events,
potentially producing a false `VXLAN_FRAGMENTATION_OBSERVED` verdict.

This document evaluates five approaches to restrict the counter to VXLAN-relevant
events, assesses feasibility on kernel 6.10.14-linuxkit aarch64, and records
the chosen v0 strategy.

---

## Option 1: ifindex filtering inside the kprobe

**Idea:** At the ip_do_fragment kprobe, read `skb->dev->ifindex` and only
count if it matches the configured underlay interface index (e.g., veth1 in ns1).

**Feasibility:** Possible in principle — `skb->dev` is a valid CO-RE access.
**Verifier risk:** Medium — pointer chasing through `skb->dev` requires BTF
relocations for `sk_buff.dev` (a net_device pointer) and then `net_device.ifindex`.
**Kernel-version risk:** Low — `sk_buff.dev` and `net_device.ifindex` have been
stable fields for many kernel versions.
**False positive risk:** HIGH — ifindex values are per-network-namespace and
are **recycled**. In a two-namespace lab:
```
  ns1: lo=1, veth1=2, vxlan0=3
  ns2: lo=1, veth2=2, vxlan0=3
```
Both veth1 (ns1) and veth2 (ns2) have `ifindex=2`. The kprobe fires in the
global kernel context (not inside ns1), so filtering by ifindex=2 would match
events from **both** namespaces. If ns2 also fragments packets, those events
would pass the filter incorrectly.
**Works on 6.10.14:** Technically possible, but the ifindex collision makes
it unreliable across namespaces. An additional netns discriminator is required.

**Verdict: NOT SUITABLE alone.** Requires combining with a netns discriminator.

---

## Option 2: netns cookie filtering (bpf_get_netns_cookie)

**Idea:** Call `bpf_get_netns_cookie(NULL)` inside the kprobe to get the
current task's netns cookie, compare to a pre-configured cookie for ns1,
and only count matching events.

**Feasibility:** Helper is NOT available for BPF_PROG_TYPE_KPROBE on this kernel.
**Verifier rejection:** `"program of this type cannot use helper bpf_get_netns_cookie#122"`
**Kernel-version risk:** HIGH — the restriction is by design (the helper's
`allowed_prog_types` does not include kprobe or sched_cls). Not a linuxkit
quirk — this restriction exists in current mainline. See `evidence/day-08-helper-availability.md`.
**Works on 6.10.14:** NO — verifier rejects unconditionally.

**Verdict: NOT FEASIBLE on this kernel (or likely any current mainline kernel).**

---

## Option 3: read skb→dev→net to get struct net pointer, compare netns

**Idea:** CO-RE-read `skb->dev->nd_net.net` (or `skb->dev->ifindex` combined
with a pre-configured per-namespace net pointer), compare to identify the target
netns.

**Feasibility:** Very difficult. `struct net *` cannot be compared safely without
helper support (`bpf_get_netns_cookie` is the designed API). Reading the raw
pointer and storing it at setup time is complex, version-sensitive, and may
expose kernel-internal addresses through the BPF map.
**Verifier risk:** HIGH — reading nested pointers through net_device requires
multiple BTF relocations; verifier may reject deeply nested pointer chains.
**Kernel-version risk:** HIGH — `nd_net.net` field layout is kernel-internal.
**Works on 6.10.14:** Untested; high implementation complexity for uncertain payoff.

**Verdict: NOT SUITABLE for v0. High complexity, high verifier risk.**

---

## Option 4: parse skb headers to check outer UDP dport=4789

**Idea:** Inside the ip_do_fragment kprobe, read the packet headers from
`skb->data` (or `skb->head + skb->network_header`) to check if the UDP
destination port is 4789 (VXLAN). If the fragmented packet is a VXLAN outer
packet, the L4 header contains dport=4789.

**Feasibility:** Possible in principle, but complex:
- At ip_do_fragment entry, the skb may have already been through GRO/segmentation;
  header offset via `skb->network_header` is required.
- Must read: outer IP header (20 B) → outer UDP header (8 B) → check dport field.
- Need to verify data linearity (`skb->data_len == 0` or use `bpf_skb_load_bytes`
  equivalent, which is not available in kprobe context).
**Verifier risk:** MEDIUM-HIGH — reading from skb->data inside a kprobe context
requires careful bounds checking; the verifier may reject non-linear skb access.
**Kernel-version risk:** MEDIUM — `network_header` offset approach is stable,
but skb layout at ip_do_fragment entry may vary by driver/encap path.
**False positive risk:** Low — checking dport=4789 is VXLAN-specific (99.99%+
of traffic on dport=4789 is VXLAN in a lab context).
**Works on 6.10.14:** Unproven. Feasibility probe would be needed (Day 9+).

**Verdict: POSSIBLE but HIGH COMPLEXITY for v0. Deferred to Day 9.**

---

## Option 5: two-signal corroboration (global frag counter + TC egress)

**Idea:** Keep the global `ip_do_fragment` counter and use the TC egress hook
on vxlan0 to record the maximum outer IP length seen during the same window.
A fragmentation verdict requires BOTH:
1. `frag_events_total > 0` (ip_do_fragment fired)
2. `max_outer_ip_len > underlay_mtu` (TC egress saw oversized VXLAN outer packet)

If only signal 1 is present, the verdict uses conservative wording:
"ip_do_fragment is a global kernel function — the counter fires for ALL
outgoing IP fragmentation on this host, not only VXLAN outer packets."

**Feasibility:** Already implemented as of Day 7. No new BPF code required.
**Verifier risk:** None — uses existing proven programs.
**Kernel-version risk:** Low — TC egress sched_cls and kprobe are both
stable program types; no experimental helpers used.
**False positive risk:** Low in the lab (only VXLAN traffic); moderate on a
busy production host (non-VXLAN fragmentation could inflate the frag counter,
but the TC egress second signal provides corroboration that VXLAN-sized packets
were also present).
**Works on 6.10.14:** YES — proven in Day 7 scenario runner (4/4 pass).

**Verdict: CHOSEN v0 STRATEGY.**

---

## Chosen v0 strategy: two-signal corroboration

Given the constraints above:
- Option 1 (ifindex): unreliable across namespaces without netns discriminator
- Option 2 (netns cookie): verifier-rejected on this (and likely all current) kernels
- Option 3 (struct net pointer): too complex, kernel-internal
- Option 4 (header parsing): feasible but high complexity; deferred to Day 9
- Option 5 (two-signal): already implemented, proven, honest about global scope

**v0 uses Option 5.** The verdict message explicitly states:
> "ip_do_fragment is a global kernel function and may include non-VXLAN
> fragmentation events on a busy host."

The `fragmentation_scope` JSON field (added in Day 8 commit 4) reports
`"global_corroborated"` when both signals are present, or `"global_unscoped"`
when only ip_do_fragment fired.

### When would the verdict be wrong?

The corroborated verdict could be a false positive if:
1. A non-VXLAN source fragments packets (incrementing frag_events_total), AND
2. Simultaneously, a VXLAN source sends large-but-not-yet-fragmented packets
   that exceed the underlay MTU as seen by TC egress (setting max_outer_ip_len
   > underlay_mtu).

In a dedicated VXLAN lab or Kubernetes node doing only overlay networking,
this scenario is unlikely. On a multi-purpose host, consider it a risk.

### Day 9+ path to tighter scoping

Option 4 (header parsing at ip_do_fragment entry) is the most promising path
to actual VXLAN-specific scoping without needing new kernel helpers. It requires:
- CO-RE access to `skb->head`, `skb->network_header`, `skb->transport_header`
- Reading outer IP header (check proto=UDP) and outer UDP header (check dport=4789)
- Bounds checking the skb data (verifier may require explicit length checks)
- A feasibility probe (compile + load + test) before committing to this path

This is scoped to Day 9 or later. It is not a v0 requirement — the two-signal
approach is honest, documented, and already proven.
