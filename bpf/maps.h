/* bpf/maps.h
 *
 * Shared struct definitions for vxlan-tracer BPF programs.
 * This header defines keys and values only — no map instances.
 * Each BPF C file declares its own maps using these types.
 *
 * Correlation note: ICMP PTB payloads carry the original outer IP header and
 * the first 8 bytes of the original outer UDP header.  The inner IP header
 * is NOT present in the PTB payload.  Therefore PTB-to-flow correlation is
 * at VTEP IP pair granularity, not at inner 5-tuple granularity.
 * See docs/forbidden-claims.md, claim #4.
 */
#pragma once

#include <linux/types.h>

/* ---- PTB ingress key/value ---- */

/* Key: the underlay IP pair that exchanged a PTB.
 * ptb_src_ip: source of the PTB (remote router or middlebox sending the error).
 * ptb_dst_ip: destination of the PTB (our underlay interface receiving the error).
 */
struct ptb_key {
	__u32 ptb_src_ip;
	__u32 ptb_dst_ip;
};

/* Value: per-VTEP-pair PTB counters seen before netfilter (TC ingress). */
struct ptb_val {
	__u64 first_seen_ns;  /* bpf_ktime_get_ns() at first PTB */
	__u64 last_seen_ns;   /* bpf_ktime_get_ns() at most recent PTB */
	__u32 ptb_count;      /* total PTBs seen for this VTEP pair */
	__u16 next_hop_mtu;   /* MTU advertised in the most recent PTB */
	__u16 pad;
};

/* ---- Overlay flow key/value (TC egress vxlan0) ---- */

/* Key: inner 5-tuple as seen at vxlan0 egress (before VXLAN encapsulation).
 * src_port / dst_port are 0 for ICMP.
 */
struct flow_key {
	__u32 src_ip;
	__u32 dst_ip;
	__u16 src_port;
	__u16 dst_port;
	__u8  proto;
	__u8  pad[3];
};

/* Value: per-flow packet observations.
 * max_inner_ip_len: largest inner IP packet seen (iph->tot_len).
 * max_outer_ip_len: max_inner_ip_len + 50 (VXLAN overhead; informational).
 *   The kernel compares this value against the underlay MTU.
 *   If max_outer_ip_len > underlay_mtu: ip_do_fragment fires (DF=0)
 *   or outer packet is dropped + PTB generated (DF=1).
 */
struct flow_val {
	__u64 last_seen_ns;
	__u32 pkt_count;
	__u16 max_inner_ip_len;
	__u16 max_outer_ip_len;  /* = max_inner_ip_len + 50 */
};

/* ---- Fragmentation event counters (ip_do_fragment kprobe) ---- */

/* Value for frag_events_total: single-entry ARRAY (key 0 → struct frag_val).
 *
 * total:        every ip_do_fragment invocation increments this.
 * last_seen_ns: bpf_ktime_get_ns() at the most recent fragmentation event.
 *               Populated in Day 6 commit 7 when skb field reads are added.
 * max_skb_len:  largest skb->len (outer packet size incl. VXLAN headers) seen
 *               across all ip_do_fragment calls.
 *               Populated in Day 6 commit 7; 0 in the count-only phase.
 * pad:          explicit padding to keep the struct 24 bytes and 8-byte aligned.
 *
 * Why struct rather than a bare u64 like icmp_rcv_total?
 *   ip_do_fragment sees the full outer skb; recording skb->len lets us confirm
 *   which packet sizes are triggering fragmentation, without any per-flow state.
 *   Using a single shared record (max not per-event) keeps the map tiny and
 *   avoids a HASH map for a diagnostic-only signal.
 *
 * Limitation: ip_do_fragment fires for ALL outgoing IP fragmentation on the
 * system, not only VXLAN outer packets.  In a lab environment with only VXLAN
 * traffic this is fine; in a production host with other fragmented traffic, the
 * count may be inflated.  A per-device filter can be added in a later day once
 * the count-only path is proven.
 */
struct frag_val {
	__u64 total;        /* ip_do_fragment invocations observed */
	__u64 last_seen_ns; /* ktime at most recent event (0 until commit 7) */
	__u32 max_skb_len;  /* max skb->len seen (0 until commit 7)           */
	__u32 pad;
};
