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
