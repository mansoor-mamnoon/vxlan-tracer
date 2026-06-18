/*
 * spikes/probe_frag_scope.bpf.c
 *
 * FEASIBILITY SPIKE — Day 8 commit 3
 *
 * Attempts to read the outer UDP destination port from the skb at
 * ip_do_fragment entry to determine if the fragmented packet is VXLAN
 * (dport=4789). If feasible, this would allow scoping frag_events_total
 * to VXLAN-specific fragmentation without needing bpf_get_netns_cookie.
 *
 * Approach:
 *   At ip_do_fragment entry, skb points to the OUTER IP packet (after
 *   VXLAN encapsulation). The packet layout at this point:
 *     skb->data = outer IP header start (after L2; ip_do_fragment is
 *                 called from the IP layer, not the ethernet layer)
 *     skb->network_header = offset from skb->head to outer IP header start
 *     outer IP header = 20 bytes (assuming no IP options)
 *     outer UDP header starts at offset 20 from the outer IP header
 *
 *   We read:
 *     outer_ip_hdr_start = skb->head + skb->network_header
 *     outer_proto = *(outer_ip_hdr_start + 9)   (ip_proto field, offset 9)
 *     outer_udp_dport = *(outer_ip_hdr_start + 20 + 2) (UDP dst port, offset 2)
 *
 * CO-RE fields used:
 *   skb->head           (unsigned char *)
 *   skb->network_header (__u16)
 *   skb->len            (__u32)
 *
 * If the verifier rejects this program, the failure is recorded in
 * evidence/day-08-frag-scope-spike.md and Option 4 from
 * docs/fragmentation-scoping.md is deferred.
 *
 * Compile:
 *   clang -O2 -g -target bpf -D__TARGET_ARCH_arm64 \
 *     -I/usr/include -I/usr/include/aarch64-linux-gnu \
 *     -c spikes/probe_frag_scope.bpf.c \
 *     -o /tmp/probe_frag_scope.bpf.o
 */

#include <linux/bpf.h>
#include <linux/ptrace.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_endian.h>

#define IPPROTO_UDP 17
#define VXLAN_PORT  4789

/*
 * Partial sk_buff with the fields needed for header access.
 * preserve_access_index emits CO-RE BTF relocations for each field.
 */
struct sk_buff {
	unsigned int          len;           /* total data length */
	unsigned char        *head;          /* head of buffer */
	unsigned char        *data;          /* start of packet data */
	__u16                 network_header; /* offset of network (IP) header from head */
	__u16                 transport_header; /* offset of transport (UDP/TCP) header from head */
} __attribute__((preserve_access_index));

/*
 * Results map: stores the findings from the last ip_do_fragment call.
 * key 0:
 *   val[0] = skb->len
 *   val[1] = outer IP proto (should be 17 for UDP/VXLAN)
 *   val[2] = outer UDP dport (should be 4789 for VXLAN)
 *   val[3] = 1 if VXLAN-scoped, 0 otherwise
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 4);
	__type(key, __u32);
	__type(value, __u64);
} frag_scope_result SEC(".maps");

/*
 * Scoped fragmentation counter — incremented only when dport=4789.
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} frag_vxlan_count SEC(".maps");

SEC("kprobe/ip_do_fragment")
int probe_frag_scope(struct pt_regs *ctx)
{
	struct sk_buff *skb = (struct sk_buff *)PT_REGS_PARM3(ctx);

	/* Read skb fields via CO-RE. */
	__u32 skb_len = BPF_CORE_READ(skb, len);
	unsigned char *head = BPF_CORE_READ(skb, head);
	__u16 net_hdr_off = BPF_CORE_READ(skb, network_header);

	/* Store skb->len for reference. */
	__u32 k0 = 0, k1 = 1, k2 = 2, k3 = 3;
	__u64 len_val = skb_len;
	bpf_map_update_elem(&frag_scope_result, &k0, &len_val, BPF_ANY);

	/*
	 * Read the outer IP protocol field.
	 * IP header layout (RFC 791): proto is byte 9 of the IP header.
	 * We read from: head + network_header + 9.
	 *
	 * Verifier requires that we provide a data bound. We use skb->len
	 * as a conservative upper bound for the linear data; this may cause
	 * the verifier to reject the access if it cannot prove the range.
	 *
	 * Fallback: use bpf_probe_read_kernel which bypasses the verifier's
	 * range check by handling faults internally.
	 */
	__u8 ip_proto = 0;
	unsigned char *ip_hdr_ptr = head + net_hdr_off;
	int ret = bpf_probe_read_kernel(&ip_proto, sizeof(ip_proto), ip_hdr_ptr + 9);
	if (ret != 0) {
		/* Could not read IP proto — header not accessible. */
		__u64 proto_val = 0xff; /* sentinel: read failed */
		bpf_map_update_elem(&frag_scope_result, &k1, &proto_val, BPF_ANY);
		return 0;
	}

	__u64 proto_val = ip_proto;
	bpf_map_update_elem(&frag_scope_result, &k1, &proto_val, BPF_ANY);

	if (ip_proto != IPPROTO_UDP) {
		/* Not UDP — definitely not VXLAN. */
		__u64 zero = 0;
		bpf_map_update_elem(&frag_scope_result, &k2, &zero, BPF_ANY);
		bpf_map_update_elem(&frag_scope_result, &k3, &zero, BPF_ANY);
		return 0;
	}

	/*
	 * Read outer UDP destination port.
	 * UDP header layout: src(2), dst(2), len(2), checksum(2).
	 * dst port is at offset 2 from UDP header start.
	 * UDP header starts 20 bytes after the outer IP header start
	 * (assuming no IP options — valid for VXLAN outer IP in Linux).
	 */
	__be16 udp_dport = 0;
	ret = bpf_probe_read_kernel(&udp_dport, sizeof(udp_dport), ip_hdr_ptr + 20 + 2);
	if (ret != 0) {
		__u64 dport_val = 0xffff; /* sentinel: read failed */
		bpf_map_update_elem(&frag_scope_result, &k2, &dport_val, BPF_ANY);
		return 0;
	}

	__u16 dport_host = bpf_ntohs(udp_dport);
	__u64 dport_val = dport_host;
	bpf_map_update_elem(&frag_scope_result, &k2, &dport_val, BPF_ANY);

	if (dport_host == VXLAN_PORT) {
		/* VXLAN outer packet. Increment scoped counter. */
		__u64 one_val = 1;
		bpf_map_update_elem(&frag_scope_result, &k3, &one_val, BPF_ANY);
		__u32 zero = 0;
		__u64 *cnt = bpf_map_lookup_elem(&frag_vxlan_count, &zero);
		if (cnt)
			__sync_fetch_and_add(cnt, 1);
	} else {
		__u64 zero_val = 0;
		bpf_map_update_elem(&frag_scope_result, &k3, &zero_val, BPF_ANY);
	}

	return 0;
}

char _license[] SEC("license") = "GPL";
