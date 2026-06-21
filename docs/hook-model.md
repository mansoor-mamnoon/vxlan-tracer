# Hook Model

This document records the correct hook placement for each diagnostic signal and
explains why alternatives were rejected.

## Signal 1 — inner packet leaving the overlay (vxlan0 egress)

**Correct hook:** TC egress on vxlan0 (cls_bpf, clsact qdisc, TC_H_MIN_EGRESS)

**Why this hook:**
TC egress fires in `ip_finish_output2` before the VXLAN driver creates the
outer skb. At this point the skb contains the inner Ethernet + IP + TCP/UDP
headers. The inner IP packet length (`skb->len` at this point minus the inner
Ethernet header, or directly from `iph->tot_len`) is directly readable without
parsing any VXLAN header.

**Rejected alternative — XDP on vxlan0:**
XDP fires on the receive/ingress path only (after NIC DMA, before protocol
demux). There is no XDP egress hook. `XDP_TX` retransmits the currently
received packet; it is not an observation hook for outgoing packets. Any tool
claiming "XDP egress" on an overlay interface is factually wrong.

**BPF program name:** `tc_egress_vxlan0`

---

## Signal 2 — outer IP fragmentation (DF=0 path, Linux default)

**Correct hook:** kprobe or fentry on `ip_do_fragment`

**Why this hook:**
Linux VXLAN defaults to DF=0 on the outer IP header. When the outer frame
exceeds the underlay MTU, `ip_do_fragment` is called to split the oversized
packet into fragments. No ICMP PTB is generated. The hook fires at the exact
moment of fragmentation, providing `skb->len` (original pre-frag outer size)
and `skb->dev->mtu` (the MTU that triggered fragmentation).

**Why this MUST be V0:**
Without this hook, the tool produces zero output on a default Flannel or Calico
VXLAN cluster. The ICMP PTB path (Signals 3–5) only fires when `df set` is
configured on the VXLAN interface, which is not the default. A tool that
requires `df set` to show any output is unusable in most real deployments.

**Symbol availability:** `ip_do_fragment` must be present in `/proc/kallsyms`.
If it is absent (inlined by the kernel build), fall back to kprobe on
`__ip_finish_output` and check for return value `EMSGSIZE` (90).

**BPF program name:** `kprobe_ip_do_fragment`

---

## Signal 3 — locally-generated ICMP PTB (DF=1 path)

**Correct hook:** kprobe or fentry on `icmp_send`

**Why this hook:**
When the outer IP has DF=1 and the outer frame exceeds the underlay MTU,
`ip_finish_output2` drops the packet and calls `icmp_send(skb, type=3, code=4,
info=next_hop_mtu)`. The `info` argument is the MTU value that will appear in
the ICMP PTB. Reading it here gives the exact next-hop MTU.

**BPF program name:** `kprobe_icmp_send`

---

## Signal 4 — remote ICMP PTB arriving at underlay (at vxlan-tracer's TC observation point)

**Correct hook:** TC ingress on the underlay interface (eth0)

**Why this hook:**
TC ingress fires at step 4 in the receive path — after GRO/netif_receive_skb
protocol demux but BEFORE netfilter PREROUTING and INPUT chains.

**Critical priority caveat:** vxlan-tracer attaches at TC priority 50000. Any TC
program with a lower priority number (e.g. Cilium at priority 1) runs BEFORE
vxlan-tracer. If an earlier TC program drops or modifies a PTB, vxlan-tracer
cannot observe it. PTB count = 0 at vxlan-tracer's hook does NOT prove no PTB
arrived at the NIC — it only proves vxlan-tracer did not observe one. This priority
was chosen for coexistence safety, not for pre-CNI observation.

The program counts PTBs where the embedded outer UDP dst port matches the configured
VXLAN port (confirming these are VXLAN-related).

**Alternative that also works but is insufficient alone:**
tcpdump via AF_PACKET (PF_PACKET socket) also fires before netfilter on ingress
and CAN see suppressed PTBs. The critical difference is that tcpdump cannot
measure whether `icmp_rcv` was subsequently called. The suppression verdict
requires both Signal 4 (TC ingress count) and Signal 5 (icmp_rcv count). A
single tcpdump session cannot produce both numbers simultaneously.

**BPF program name:** `tc_ingress_eth0`

**ICMP PTB content limitation:**
The embedded IP + UDP bytes in the PTB allow verification that the PTB is
VXLAN-related (dst_port == 4789). They do NOT contain the inner IP header.
The inner flow 5-tuple is not recoverable from the PTB payload.

---

## Signal 5 — ICMP PTB reaching icmp_rcv (after netfilter)

**Correct hook:** fentry on `icmp_rcv` (or kprobe if BTF unavailable)

**Why this hook:**
`icmp_rcv` fires at step 8 in the receive path — after netfilter INPUT. If
iptables contains a rule like `-A INPUT -p icmp --icmp-type
fragmentation-needed -j DROP`, the ICMP PTB is dropped before `icmp_rcv` is
ever called. Counting invocations of `icmp_rcv` for type=3 code=4 packets
and comparing to the Signal 4 TC ingress count detects this suppression.

**Suppression verdict logic:**
```
total_ptbs_at_tc_ingress = sum of ptb_events[*].ptb_count
total_ptbs_at_icmp_rcv   = ptb_processed[0]

if total_ptbs_at_tc_ingress > 0 AND total_ptbs_at_icmp_rcv == 0:
    SUPPRESSION CONFIRMED — iptables or nftables INPUT dropping ICMP frag-needed
```

**BPF program name:** `fentry_icmp_rcv`

---

## Optional — outer frame size at eth0 egress

**Hook:** TC egress on eth0

**Limitation:** For DF=1 oversized outer packets, the drop happens inside
`ip_finish_output2` before TC egress fires. TC egress on eth0 never sees these
dropped packets. It is useful only in DF=0 configurations for confirming outer
frame sizes. Marked optional/debug.

---

## Hook ordering in the Linux kernel receive path

For reference (numbers match the architecture doc):

1. NIC DMA → ring buffer
2. NAPI poll
3. **XDP** (ingress only — not used here)
4. GRO → netif_receive_skb → protocol demux
5. **TC ingress** (cls_bpf — fires here, before netfilter) ← Signal 4
6. netfilter PREROUTING
7. ip_rcv → routing
8. netfilter INPUT (iptables/nftables)
9. ip_local_deliver_finish → **icmp_rcv** ← Signal 5
10. icmp_unreach → PMTU cache update

## Hook ordering in the Linux kernel transmit path

1. Application → socket → TCP/UDP
2. IP layer (ip_output)
3. ip_finish_output → ip_finish_output2 → netfilter POSTROUTING
4. **TC egress** on vxlan0 ← Signal 1 (inner packet, before VXLAN encap)
5. VXLAN driver creates outer skb
6. ip_finish_output2 on eth0
   - DF=0 + oversized: **ip_do_fragment** ← Signal 2
   - DF=1 + oversized: drop + **icmp_send** ← Signal 3
7. **TC egress** on eth0 (optional debug; misses DF=1 drops)
8. dev_queue_xmit → NIC driver → wire
