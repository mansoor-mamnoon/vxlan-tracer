/*
 * bpf/kprobes.bpf.c
 *
 * Kprobe BPF program for post-netfilter ICMP PTB counting.
 *
 * Hook: kprobe/icmp_rcv
 *
 * Kernel path for incoming ICMP:
 *   NIC → TC ingress (clsact) → ip_rcv → netfilter INPUT → icmp_rcv
 *
 * icmp_rcv fires AFTER the netfilter INPUT chain. If iptables has a DROP rule
 * for ICMP type 3 code 4, the packet is discarded before icmp_rcv and this
 * counter does NOT increment.
 *
 * Day 5 update: filters to ICMP type 3 code 4 only.
 *   Day 4 counted all icmp_rcv calls (valid only in isolated lab traffic with
 *   no other ICMP). This update makes the counter meaningful in environments
 *   with ping traffic or other ICMP types.
 *
 * Approach: partial struct sk_buff declaration with preserve_access_index.
 * This causes clang to emit a CO-RE BTF field relocation for skb->data.
 * libbpf resolves the actual offset at load time from /sys/kernel/btf/vmlinux.
 * Does not require vmlinux.h or a full BTF header — only BTF at load time.
 *
 * At icmp_rcv entry, ip_local_deliver_finish has called:
 *   __skb_pull(skb, skb_network_header_len(skb))
 * which moves skb->data past the IP header. skb->data therefore points to the
 * start of the ICMP header (type at offset 0, code at offset 1).
 *
 * Suppression detection signal (unchanged from Day 4):
 *   TC ingress count > 0   AND   icmp_rcv_total == 0
 *   → PTBs arrived at underlay but iptables/nft dropped them before icmp_rcv
 */

#include <linux/bpf.h>
#include <linux/ptrace.h>      /* struct user_pt_regs for PT_REGS_ARM64 on aarch64 */
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#define ICMP_DEST_UNREACH  3
#define ICMP_FRAG_NEEDED   4

/*
 * Partial sk_buff for CO-RE: only the 'data' field is declared.
 * preserve_access_index tells clang to emit a BTF relocation for every access
 * to a member of this struct, so the actual byte offset is resolved at
 * load time rather than baked in at compile time.
 */
struct sk_buff {
	unsigned char *data;
} __attribute__((preserve_access_index));

/*
 * Map: global count of icmp_rcv invocations for ICMP PTBs only (post-netfilter).
 * Single-entry ARRAY: key 0 → u64 count.
 * Day 4: counted all icmp_rcv calls.
 * Day 5: filters to type=3 code=4 before incrementing.
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key,   __u32);
	__type(value, __u64);
} icmp_rcv_total SEC(".maps");

SEC("kprobe/icmp_rcv")
int kprobe_icmp_rcv(struct pt_regs *ctx)
{
	struct sk_buff *skb = (struct sk_buff *)PT_REGS_PARM1(ctx);

	/*
	 * Read skb->data via CO-RE relocation.
	 * At icmp_rcv entry, skb->data points to the ICMP header start
	 * (ip_local_deliver_finish pulled past the IP header before dispatching).
	 */
	unsigned char *data = (unsigned char *)BPF_CORE_READ(skb, data);

	__u8 type = 0, code = 0;
	if (bpf_probe_read_kernel(&type, sizeof(type), data) < 0)
		return 0;
	if (bpf_probe_read_kernel(&code, sizeof(code), data + 1) < 0)
		return 0;

	/* Only count ICMP Destination Unreachable / Fragmentation Needed */
	if (type != ICMP_DEST_UNREACH || code != ICMP_FRAG_NEEDED)
		return 0;

	__u32 zero = 0;
	__u64 *total = bpf_map_lookup_elem(&icmp_rcv_total, &zero);
	if (total)
		__sync_fetch_and_add(total, 1);
	return 0;
}

char _license[] SEC("license") = "GPL";
