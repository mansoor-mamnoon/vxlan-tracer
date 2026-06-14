# Architecture

## Problem statement

VXLAN encapsulation adds 50 bytes of overhead:

```
outer Ethernet header : 14 bytes
outer IP header       : 20 bytes
outer UDP header      :  8 bytes
VXLAN header          :  8 bytes
                        --------
total overhead        : 50 bytes
```

If the overlay interface MTU is set to 1500 (matching the underlay), an inner
IP packet of 1500 bytes becomes an outer frame of 1564 bytes — 64 bytes over
the typical underlay MTU of 1500. The safe overlay MTU is:

```
vxlan0_MTU = underlay_MTU − 50
           = 1500 − 50
           = 1450 bytes
```

The kernel's behavior for oversized outer packets depends on the DF bit on the
outer IP header:

- **DF=0 (default for Linux VXLAN):** kernel fragments the oversized outer
  packet via `ip_do_fragment`. Fragmented VXLAN UDP is dropped by most cloud
  provider fabric (AWS VPC, GCP, Azure) and many middleboxes.
- **DF=1 (configured with `ip link ... df set`):** kernel drops the packet and
  generates an ICMP Type 3 Code 4 (Packet Too Big / fragmentation-needed)
  message toward the inner flow's socket.

## Hook placement

```
Transmit path (inner packet leaving overlay):

  Application → socket → TCP/UDP → IP layer
    → ip_output → ip_finish_output2
      → [TC egress on vxlan0] ← HOOK 1: inner 5-tuple + pkt size
      → vxlan driver encapsulates (inner → outer skb)
        → ip_finish_output2 on eth0
          → if outer > MTU and DF=0: ip_do_fragment ← HOOK 2: fragmentation
          → if outer > MTU and DF=1: drop + icmp_send  ← HOOK 3: local PTB
          → [TC egress on eth0]  ← optional debug only (DF=1 drops happen BEFORE this)
          → dev_queue_xmit → NIC → wire

Receive path (ICMP PTB coming back from remote):

  NIC DMA → ring buffer → NAPI poll
    → [XDP — not used; ingress-only, not relevant here]
    → GRO → netif_receive_skb
      → [TC ingress on eth0] ← HOOK 4: pre-netfilter PTB count
      → netfilter PREROUTING → netfilter INPUT (iptables)
      → ip_local_deliver_finish → icmp_rcv ← HOOK 5: post-netfilter PTB count
        → icmp_unreach → PMTU cache update
```

**Suppression detection:** if HOOK 4 count > 0 AND HOOK 5 count == 0, then
iptables is dropping incoming PTBs before the kernel can process them. TCP
never receives a path MTU update, so the flow stalls permanently.

## Why not XDP

XDP fires on the ingress (receive) path only. There is no XDP egress hook.
`XDP_TX` retransmits the current received packet back out the same device — it
is not an observation hook for outgoing packets.

All outgoing-packet observation in vxlan-tracer uses TC BPF (cls_bpf attached
to a clsact qdisc) because TC has both ingress and egress directions.

## TC egress on eth0 — limited utility

TC egress on eth0 fires AFTER `ip_finish_output2` has already decided to
fragment or drop the outer packet. For DF=1 oversized packets, the drop occurs
inside `ip_finish_output2` before control returns to TC. This means TC egress
on eth0 never sees DF=1 drops. It is useful for observing actual outer frame
sizes in DF=0 configurations but is marked optional in the implementation.

## ICMP PTB content

ICMP Type 3 Code 4 (fragmentation-needed) payload contains:

```
ICMP header        :  8 bytes (type, code, checksum, unused, next_hop_mtu)
Embedded IP header : 20 bytes (outer IP: src=our_eth0, dst=remote_vtep)
Embedded IP data   :  8 bytes (outer UDP header: src_port, dst_port=4789, len, checksum)
```

The **inner** IP header and inner TCP/UDP header are NOT included. Inner flow
5-tuple cannot be extracted from an ICMP PTB. Correlation of PTBs to inner
flows is at VTEP IP granularity only: "flows to remote_vtep X may be affected."

## BPF program inventory

| Program | Attach point | Direction | V0/V1 | Purpose |
|---------|-------------|-----------|-------|---------|
| tc_egress_vxlan0 | clsact on vxlan0 | egress | V0 | Read inner 5-tuple + pkt size before encap |
| tc_ingress_eth0 | clsact on eth0 | ingress | V0 | Count ICMP PTBs before iptables |
| kprobe_ip_do_fragment | ip_do_fragment | — | V0 | Detect outer-packet fragmentation (DF=0) |
| kprobe_icmp_send | icmp_send | — | V0 | Detect locally-generated PTBs (DF=1) |
| fentry_icmp_rcv | icmp_rcv | — | V0 | Count PTBs after iptables (suppression signal) |

## BPF map inventory

| Map | Type | Key | Value | Purpose |
|-----|------|-----|-------|---------|
| flow_state | HASH (65536) | flow_key (5-tuple) | flow_val (size, timestamp, vtep) | Track inner flows seen at vxlan0 egress |
| ptb_events | HASH (1024) | ptb_key (src_ip, dst_ip) | ptb_val (count, mtu, timestamp) | ICMP PTBs seen at TC ingress |
| ptb_processed | ARRAY (1) | u32 index 0 | u64 counter | icmp_rcv invocation count |
| frag_events | HASH (1024) | u32 vtep_ip | frag_val (count, orig_len, timestamp) | ip_do_fragment events per VTEP |
| config | ARRAY (1) | u32 index 0 | config_val (vxlan_port, underlay_ifindex) | Shared config readable by all programs |

## Go userspace controller

The controller polls all five maps every 100ms, runs MTU arithmetic, compares
ptb_events totals against ptb_processed, and emits a structured diagnosis.

MTU arithmetic is computed by the controller, not in BPF:
```
safe_vxlan_mtu   = underlay_mtu - 50
projected_outer  = inner_ip_len + 64   (inner_ip_len + overhead without outer ETH)
projected_frame  = inner_ip_len + 14 + 50   (with outer ETH)
excess           = projected_frame - underlay_mtu
```

The `inner_ip_len` field in BPF is the actual `skb->len` at TC egress on
vxlan0, which at that point is the inner IP packet length (no encap headers).

## Kernel version support

| Feature | Minimum kernel |
|---------|---------------|
| TC BPF (cls_bpf / clsact) | 4.1+ |
| fentry | 5.5+ |
| BTF / CO-RE | 5.4+ |
| kfree_skb drop reasons | 5.17+ |
| Recommended | 5.15 LTS |

## Known unknowns (as of day 1)

1. `ip_do_fragment` symbol availability varies by kernel config. Must verify
   with `grep ip_do_fragment /proc/kallsyms` on target kernel. If the symbol
   is absent (inlined), fall back to `__ip_finish_output` kprobe.
2. clsact qdisc may already exist on target interfaces (e.g., Cilium installs
   it). Controller must handle EEXIST and must NOT delete the qdisc on exit.
3. The BPF verifier will reject the `ihl * 4` pointer offset unless an explicit
   bounds check (`if ihl < 5 || ihl > 15`) is placed before the offset use.
4. `bpf_fib_lookup` for VTEP resolution is deferred to V1.
