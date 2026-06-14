/*
 * bpf/tc_egress_vxlan0.bpf.c
 *
 * TC classifier (sched_cls) attached to vxlan0 egress in ns1.
 *
 * At vxlan0 egress the kernel sees the inner packet BEFORE VXLAN encapsulation.
 * The frame is: inner ETH + inner IP [+ inner TCP/UDP].
 * The kernel will add inner ETH(14) + outer IP(20) + outer UDP(8) + VXLAN(8) = 50 bytes
 * before the packet hits the underlay, so the outer IP length = inner IP tot_len + 50.
 *
 * Purpose: record every inner flow passing through the overlay so that after a
 * blackhole event we can say:
 *   "flow {src→dst:dport} had max inner IP len N → outer IP len N+50;
 *    underlay MTU is M; if N+50 > M the outer packet could not fit."
 *
 * This is observational only: TC_ACT_OK is always returned; no packets are dropped.
 *
 * Attach:
 *   tc qdisc add dev vxlan0 clsact
 *   tc filter add dev vxlan0 egress bpf da obj tc_egress_vxlan0.bpf.o sec tc
 *
 * Map: flow_state (HASH, flow_key → flow_val) — one entry per inner 5-tuple.
 *
 * Verifier constraints handled:
 *   - All packet pointer accesses bounds-checked before dereference.
 *   - ihl clamped to [5, 15] before use as variable offset.
 *   - Struct initialised with = {} to clear padding; verifier requires no
 *     uninitialised bytes in map keys.
 *   - __sync_fetch_and_add for atomic increments on shared map values.
 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>

#include "maps.h"

/* Overhead that vxlan0 egress adds before the outer IP packet hits the underlay.
 * inner ETH(14) + outer IP hdr(20) + outer UDP(8) + VXLAN hdr(8) = 50. */
#define VXLAN_OVERHEAD 50

/* Map: per inner-5-tuple flow observations. */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 4096);
	__type(key,   struct flow_key);
	__type(value, struct flow_val);
} flow_state SEC(".maps");

SEC("tc")
int tc_egress_track_flow(struct __sk_buff *skb)
{
	void *data     = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;

	/* ---- Inner Ethernet header ---- */
	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return TC_ACT_OK;

	if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
		return TC_ACT_OK;

	/* ---- Inner IPv4 header ---- */
	struct iphdr *iph = (struct iphdr *)(eth + 1);
	if ((void *)(iph + 1) > data_end)
		return TC_ACT_OK;

	__u8 ihl = iph->ihl;
	if (ihl < 5 || ihl > 15)
		return TC_ACT_OK;

	/* ---- Build flow key ---- */
	struct flow_key key = {};
	key.src_ip = iph->saddr;
	key.dst_ip = iph->daddr;
	key.proto  = iph->protocol;

	/* ---- Extract ports for TCP and UDP ---- */
	void *transport = (void *)iph + ((__u32)ihl << 2);

	if (iph->protocol == IPPROTO_TCP) {
		struct tcphdr *tcph = transport;
		if ((void *)(tcph + 1) <= data_end) {
			key.src_port = tcph->source;
			key.dst_port = tcph->dest;
		}
	} else if (iph->protocol == IPPROTO_UDP) {
		struct udphdr *udph = transport;
		if ((void *)(udph + 1) <= data_end) {
			key.src_port = udph->source;
			key.dst_port = udph->dest;
		}
	}
	/* For ICMP and other protocols, src_port/dst_port remain 0 (zero-init). */

	/* ---- Inner IP packet length and projected outer IP length ----
	 * iph->tot_len is in network byte order; convert to host order.
	 * The outer IP packet = inner_ip_len + VXLAN_OVERHEAD.
	 * This is what the kernel compares against the underlay MTU. */
	__u16 inner_ip_len = bpf_ntohs(iph->tot_len);
	__u16 outer_ip_len = inner_ip_len + VXLAN_OVERHEAD;

	/* ---- Update or insert flow_state entry ---- */
	struct flow_val *val = bpf_map_lookup_elem(&flow_state, &key);
	if (val) {
		__sync_fetch_and_add(&val->pkt_count, 1);
		val->last_seen_ns = bpf_ktime_get_ns();
		/* Track maximum inner and outer IP lengths seen for this flow. */
		if (inner_ip_len > val->max_inner_ip_len)
			val->max_inner_ip_len = inner_ip_len;
		if (outer_ip_len > val->max_outer_ip_len)
			val->max_outer_ip_len = outer_ip_len;
	} else {
		struct flow_val new_val = {};
		new_val.last_seen_ns     = bpf_ktime_get_ns();
		new_val.pkt_count        = 1;
		new_val.max_inner_ip_len = inner_ip_len;
		new_val.max_outer_ip_len = outer_ip_len;
		bpf_map_update_elem(&flow_state, &key, &new_val, BPF_ANY);
	}

	return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
