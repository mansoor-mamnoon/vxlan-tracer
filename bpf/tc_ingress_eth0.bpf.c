/*
 * bpf/tc_ingress_eth0.bpf.c
 *
 * TC classifier (sched_cls) attached to the underlay interface ingress.
 * In the lab topology this is veth1 in ns1; in production it is the physical
 * or bond interface that carries encapsulated VXLAN traffic.
 *
 * Purpose: count ICMP Packet Too Big (type=3 code=4) messages BEFORE they
 * reach netfilter (iptables/nft INPUT chain).  This is the first half of
 * the PTB suppression detection signal.  The second half is icmp_rcv count
 * (post-netfilter), which will be implemented in kprobes.bpf.c.
 *
 * Suppression signal:
 *   ptb_ingress_counts[vtep_pair] > 0  AND  icmp_rcv_count == 0
 *   → PTBs arrived at underlay but were dropped before icmp_rcv.
 *     Likely cause: iptables/nft rule dropping ICMP type 3 code 4.
 *
 * Attach:
 *   tc qdisc add dev <underlay> clsact
 *   tc filter add dev <underlay> ingress bpf da obj tc_ingress_eth0.bpf.o sec tc
 *
 * This program never drops packets: always returns TC_ACT_OK.
 *
 * Verifier constraints observed and handled:
 *   - Every pointer into packet data is bounds-checked before dereference.
 *   - iph->ihl is clamped to [5, 15] before use as pointer offset.
 *   - Atomic __sync_fetch_and_add used for map value increments (kernel 5.12+).
 *   - Stack structs initialised with = {} to avoid uninitialised-value rejections.
 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/icmp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>

#include "maps.h"

/* VXLAN destination UDP port in network byte order. */
#define VXLAN_UDP_PORT_NBO  bpf_htons(4789)

/* Map: per-VTEP-pair PTB counter (ingress, before netfilter). */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 1024);
	__type(key,   struct ptb_key);
	__type(value, struct ptb_val);
} ptb_ingress_counts SEC(".maps");

/* Map: global PTB total seen on this interface (single ARRAY entry). */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key,   __u32);
	__type(value, __u64);
} ptb_ingress_total SEC(".maps");

SEC("tc")
int tc_ingress_count_ptb(struct __sk_buff *skb)
{
	void *data     = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;

	/* ---- Ethernet header ---- */
	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return TC_ACT_OK;

	/* Only IPv4. */
	if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
		return TC_ACT_OK;

	/* ---- IPv4 header ---- */
	struct iphdr *iph = (struct iphdr *)(eth + 1);
	if ((void *)(iph + 1) > data_end)
		return TC_ACT_OK;

	/* Only ICMP. */
	if (iph->protocol != IPPROTO_ICMP)
		return TC_ACT_OK;

	/* Validate IHL before using it as a byte offset.
	 * ihl is in units of 32-bit words; valid range 5-15 (20-60 bytes).
	 * The verifier can track this as a scalar in [20, 60] after the clamp. */
	__u8 ihl = iph->ihl;
	if (ihl < 5 || ihl > 15)
		return TC_ACT_OK;

	/* ---- ICMP header ---- */
	struct icmphdr *icmph = (struct icmphdr *)((void *)iph + ((__u32)ihl << 2));
	if ((void *)(icmph + 1) > data_end)
		return TC_ACT_OK;

	/* Only PTB: Destination Unreachable (3) / Fragmentation Needed (4). */
	if (icmph->type != ICMP_DEST_UNREACH || icmph->code != ICMP_FRAG_NEEDED)
		return TC_ACT_OK;

	/* ---- Embedded original IP header (follows ICMP header) ----
	 * RFC 792: ICMP error messages embed the original IP header and the
	 * first 8 bytes of the original transport header.  For VXLAN PTBs
	 * the original transport is UDP with destination port 4789.
	 *
	 * If the embedded headers are truncated we count the PTB conservatively
	 * (it still signals that a PTB arrived, even if we cannot confirm VXLAN).
	 */
	struct iphdr *orig_iph = (struct iphdr *)(icmph + 1);
	if ((void *)(orig_iph + 1) > data_end)
		goto update_map;  /* truncated: count conservatively */

	/* If embedded protocol is not UDP, this PTB is not VXLAN-related. */
	if (orig_iph->protocol != IPPROTO_UDP)
		return TC_ACT_OK;

	__u8 orig_ihl = orig_iph->ihl;
	if (orig_ihl < 5 || orig_ihl > 15)
		goto update_map;  /* malformed embedded IP; count conservatively */

	/* ---- Embedded original UDP header ---- */
	struct udphdr *orig_udph =
		(struct udphdr *)((void *)orig_iph + ((__u32)orig_ihl << 2));
	if ((void *)(orig_udph + 1) > data_end)
		goto update_map;  /* truncated: count conservatively */

	/* Confirm destination port is VXLAN (4789). */
	if (orig_udph->dest != VXLAN_UDP_PORT_NBO)
		return TC_ACT_OK;

update_map:;
	/* ---- Update per-VTEP-pair map ---- */
	struct ptb_key key = {};
	key.ptb_src_ip = iph->saddr;
	key.ptb_dst_ip = iph->daddr;

	__u16 next_hop_mtu = bpf_ntohs(icmph->un.frag.mtu);

	struct ptb_val *val = bpf_map_lookup_elem(&ptb_ingress_counts, &key);
	if (val) {
		__sync_fetch_and_add(&val->ptb_count, 1);
		val->last_seen_ns  = bpf_ktime_get_ns();
		val->next_hop_mtu  = next_hop_mtu;
	} else {
		struct ptb_val new_val = {};
		new_val.first_seen_ns = bpf_ktime_get_ns();
		new_val.last_seen_ns  = new_val.first_seen_ns;
		new_val.ptb_count     = 1;
		new_val.next_hop_mtu  = next_hop_mtu;
		bpf_map_update_elem(&ptb_ingress_counts, &key, &new_val, BPF_ANY);
	}

	/* ---- Update global total ---- */
	__u32 zero = 0;
	__u64 *total = bpf_map_lookup_elem(&ptb_ingress_total, &zero);
	if (total)
		__sync_fetch_and_add(total, 1);

	return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
