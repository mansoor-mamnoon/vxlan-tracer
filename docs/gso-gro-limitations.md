# GSO/GRO Limitations at the TC Overlay Egress Hook

**Status:** Documented limitation — rc2 conservatively qualifies MTU conclusions when
the observation was made at a TC hook where GSO super-packets may appear.

---

## Background

Generic Segmentation Offload (GSO) allows the kernel to delay packet segmentation until
just before transmission. The kernel builds a single "super-packet" that may be much
larger than the wire MTU and passes it through the networking stack, including TC hooks,
before the NIC or software segmentation splits it into wire-sized frames.

Generic Receive Offload (GRO) does the reverse on ingress: the kernel coalesces multiple
received segments into a single larger SKB for processing efficiency.

---

## How this affects vxlan-tracer

### TC overlay egress hook (`tc_egress_vxlan0.bpf.c`)

vxlan-tracer's TC egress hook on the overlay interface captures
`skb->len` (or the equivalent CO-RE accessor) to record the outer IP packet length for
each flow in `flow_state.max_outer_ip_len`.

**The problem:** At the TC egress hook, `skb->len` may reflect the GSO super-packet
size, not the wire packet size. If the NIC driver (or the GSO software path) handles
segmentation after the TC hook, a single SKB observed at TC egress may be, for example,
65507 bytes — much larger than the 1500-byte underlay MTU — yet produce wire frames of
correct size with no fragmentation or packet loss.

In this case, vxlan-tracer would observe `max_outer_ip_len = 65507` and
`underlay_mtu = 1500`, triggering `VXLAN_MTU_RISK`:
```
max_outer_ip_len (65507) > underlay_mtu (1500) — consistent with oversized traffic
```
This would be a **false positive**: no fragmentation is occurring because the NIC or GSO
software handles segmentation after the TC hook.

### Conditions that cause false positives

| Condition | Result at TC egress |
|-----------|-------------------|
| GSO enabled on overlay NIC + large TCP send | super-packet `skb->len` may >> MTU |
| `ethtool -k <iface>` shows `tx-checksumming: on` | GSO likely enabled |
| Virtual NICs in VMs (virtio-net, vmxnet3) | typically GSO-enabled by default |
| Physical NICs with TSO enabled | TSO can produce super-packets at TC hook |

### Conditions where TC egress `skb->len` is wire-accurate

| Condition | Result |
|-----------|--------|
| GSO disabled (`ethtool -K <iface> tx off`) | `skb->len` reflects wire-size fragments |
| VXLAN with `DF` set (inner packet DF=1) | kernel fragments or generates PTB; no super-packet |
| Test traffic with small packet sizes | always wire-accurate |
| UDP test traffic (iperf3 -u) | no GSO aggregation |

### TC underlay ingress hook (`tc_ingress_eth0.bpf.c`)

The ingress hook is on the receive path after GRO coalescing. GRO may combine multiple
received ICMP PTBs? No — GRO only coalesces TCP data segments, not ICMP. PTB packets
(ICMP type 3 code 4) are not subject to GRO. The PTB counter at TC ingress is
**unaffected by GRO** and is reliable.

---

## What vxlan-tracer currently does

No GSO detection is implemented in rc2. The egress TC hook records `max_outer_ip_len`
from `skb->len` without qualifying whether the SKB is a GSO super-packet.

The `VXLAN_MTU_RISK` verdict is therefore **potentially unreliable** when GSO is enabled
on the overlay interface:
- A large `max_outer_ip_len` with no `ip_do_fragment` events may be explained by GSO
  rather than by an actual MTU problem.
- The verdict message should be treated as a hypothesis, not a confirmation.

The `VXLAN_FRAGMENTATION_OBSERVED` verdict via `ip_do_fragment` is **not affected** by
GSO: `ip_do_fragment` is called when the IP layer actually fragments a packet, which
happens after GSO segmentation (GSO-produced segments that are still too large for the
path get fragmented). If `ip_do_fragment` fires, fragmentation is real.

The `PTB_SUPPRESSED` and `PTB_DELIVERED` verdicts via TC ingress and `icmp_rcv` are
**not affected** by GSO.

---

## Verdict reliability summary with GSO enabled

| Verdict | Affected by GSO? | Reliability with GSO on |
|---------|-----------------|------------------------|
| `VXLAN_FRAGMENTATION_OBSERVED` | No | High — ip_do_fragment fires after GSO |
| `PTB_SUPPRESSED` | No | High — PTBs not subject to GRO |
| `PTB_DELIVERED` | No | High |
| `VXLAN_MTU_RISK` | Yes | **Low** — max_outer_ip_len may be GSO super-packet |
| `VXLAN_MTU_MISCONFIGURATION` | No | High — based on interface MTU config, not traffic |
| `NO_ISSUE_OBSERVED` | Indirectly | A false VXLAN_MTU_RISK would become NO_ISSUE if max_outer_ip_len is small |

---

## Mitigation chosen for rc2: conservative qualification

For rc2, vxlan-tracer takes the conservative approach: when reporting `VXLAN_MTU_RISK`,
the human-readable output and JSON output **do not claim fragmentation has occurred**;
they report only "oversized traffic signal was observed" and note that GSO may explain
the observation on hosts with offload enabled.

The technical article and outreach copy must not claim `VXLAN_MTU_RISK` definitively
proves oversized wire traffic.

**Full mitigation options for future releases:**

1. **Read `skb_is_gso(skb)` in the BPF program.** If the SKB is a GSO super-packet,
   skip recording its length or record it separately. This requires verifying that
   `skb_is_gso` is accessible via CO-RE on supported kernels (5.15+).

2. **Use `skb_shinfo(skb)->gso_size`** to find the per-segment size when GSO is active.
   This is the actual wire-frame size and is what should be compared against the MTU.

3. **Check NIC offload settings** at attach time using `ethtool` (via netlink) and emit
   a warning if GSO is enabled on the overlay interface.

4. **Use UDP test traffic** in demo scripts (prevents GSO from aggregating test packets).

---

## Integration test note

The current netns lab (`scripts/setup-netns.sh`) uses veth pairs. veth interfaces have
software GSO enabled by default but in a netns lab:
- Traffic generated by `ping` is ICMP — not subject to GSO segmentation.
- Traffic generated by `iperf3 -u` is UDP — not aggregated by GSO (GSO only applies to
  TCP and certain UDP paths).
- The `scripts/smoke-large-traffic.sh` and `scripts/smoke-small-traffic.sh` scripts use
  `dd`/netcat or `iperf3`; their GSO interaction has not been audited.

**For rc2:** The lab scenarios do not disable GSO on veth pairs. Observed
`max_outer_ip_len` values in lab runs may reflect GSO super-packet sizes if TCP is used.
This is **not tested** and **not documented in lab evidence**.

Adding `ethtool -K <iface> tx off` to `scripts/setup-netns.sh` before running TC
scenarios would make the lab GSO-free, but this change is not made in rc2 to avoid
changing the validated lab setup.

---

## Outreach implication

Do not contact the Calico GRO/GSO issue (L016 in `outreach/lead-list.md`) in rc2.
The `VXLAN_MTU_RISK` verdict's reliability when GSO is involved is not adequately
characterized. Outreach messages for `VXLAN_MTU_RISK`-class issues should note that
the signal "may be explained by GSO on the overlay NIC — check `ethtool -k <iface>`
and look for `tx-checksumming: on` or `generic-segmentation-offload: on`."

---

## References

- Linux kernel: `include/linux/skbuff.h` — `skb_is_gso()`, `skb_shinfo()`
- cilium/ebpf CO-RE field access for SKB headers
- `Documentation/networking/segmentation-offloads.rst` in the Linux kernel tree
- `docs/tc-lifecycle-audit.md` — TC hook observation point limitations
