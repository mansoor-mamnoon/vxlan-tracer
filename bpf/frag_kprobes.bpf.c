/*
 * bpf/frag_kprobes.bpf.c
 *
 * Kprobe BPF program for counting ip_do_fragment invocations and recording
 * the largest skb length seen at each call.
 *
 * Hook: kprobe/ip_do_fragment
 *
 * Kernel path for DF=0 VXLAN outer packets that exceed the underlay MTU:
 *   vxlan0 egress (TC egress BPF) → ip_output → ip_finish_output →
 *   ip_finish_output2 → ip_do_fragment
 *
 * ip_do_fragment fires when the kernel fragments an outgoing IP packet
 * because it exceeds the path MTU and the DF (Don't Fragment) bit is 0.
 * For Linux VXLAN with the default DF=0 outer header, an oversized outer
 * IP packet (inner_ip_len + 50 VXLAN overhead > underlay MTU) causes
 * ip_do_fragment to fire. The fragments may or may not be reassembled at
 * the far end — cloud fabric and AWS/GCP/Azure VPC routers commonly drop
 * fragmented UDP, causing a silent VXLAN blackhole with no PTB or error.
 *
 * ip_do_fragment signature (kernel ≥ 4.20):
 *   int ip_do_fragment(struct net *net, struct sock *sk, struct sk_buff *skb,
 *                      int (*output)(...))
 *   arg1 = net  (PT_REGS_PARM1)
 *   arg2 = sk   (PT_REGS_PARM2)
 *   arg3 = skb  (PT_REGS_PARM3) ← used here to read skb->len
 *   arg4 = fn   (PT_REGS_PARM4)
 *
 * Day 6 commit 7: CO-RE partial sk_buff for skb->len.
 *   skb->len at ip_do_fragment entry is the total linear + fragmented length
 *   of the outer IP packet (inner IP + VXLAN 50-byte overhead). Recording
 *   max_skb_len lets callers confirm which outer packet sizes are triggering
 *   fragmentation without needing to reconstruct the packet from other sources.
 *
 * CO-RE approach: partial struct sk_buff with preserve_access_index. clang
 * emits a BTF field relocation for the sk_buff.len access; cilium/ebpf
 * resolves the actual byte offset at load time from /sys/kernel/btf/vmlinux.
 * Does NOT require vmlinux.h or a full BTF header file.
 *
 * Compile flags required (compared to count-only commit 2):
 *   -D__TARGET_ARCH_arm64   (needed for PT_REGS_PARM3 on aarch64)
 *   -bpf_core_read.h is pulled in via bpf_helpers.h or explicitly included.
 *
 * Scope limitation: this hook fires for ALL IP fragmentation on the host,
 * not only VXLAN outer packets. In the lab topology (only VXLAN traffic)
 * this is equivalent. A per-device filter is deferred.
 */

#include <linux/bpf.h>
#include <linux/ptrace.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "maps.h"

/*
 * Partial sk_buff for CO-RE: only the 'len' field is declared.
 * preserve_access_index tells clang to emit a BTF relocation for every
 * member access, so the actual byte offset is resolved at load time from
 * /sys/kernel/btf/vmlinux rather than baked in at compile time.
 *
 * skb->len at ip_do_fragment entry: total length of the sk_buff data
 * (sum of all segments, including frags). For a non-fragmented outer
 * packet this equals the outer IP total length. After ip_do_fragment
 * creates fragments, each fragment has its own skb with a smaller len,
 * but the kprobe fires ONCE on the original pre-fragment skb, so len
 * here is the pre-fragment outer packet size.
 */
struct sk_buff {
	unsigned int len;
} __attribute__((preserve_access_index));

/*
 * Map: global fragmentation event record.
 * Single-entry ARRAY: key 0 → struct frag_val.
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key,   __u32);
	__type(value, struct frag_val);
} frag_events_total SEC(".maps");

SEC("kprobe/ip_do_fragment")
int kprobe_ip_do_fragment(struct pt_regs *ctx)
{
	/*
	 * ip_do_fragment(struct net *net, struct sock *sk, struct sk_buff *skb, ...)
	 * skb is the third argument. PT_REGS_PARM3 reads ctx->regs[2] on arm64.
	 * Requires -D__TARGET_ARCH_arm64 at compile time.
	 */
	struct sk_buff *skb = (struct sk_buff *)PT_REGS_PARM3(ctx);

	__u32 zero = 0;
	struct frag_val *v = bpf_map_lookup_elem(&frag_events_total, &zero);
	if (!v)
		return 0;

	__sync_fetch_and_add(&v->total, 1);

	/*
	 * Read skb->len via CO-RE relocation.
	 * This gives the total outer packet length at ip_do_fragment entry
	 * (before fragmentation splits the skb). In a stale-MTU VXLAN lab
	 * with underlay MTU=1400 and inner IP 1388B, the outer IP is 1438B
	 * and skb->len is approximately 1452B (includes L2 headers seen by
	 * the skb, varies by driver/device).
	 */
	__u32 skb_len = BPF_CORE_READ(skb, len);
	__u64 now = bpf_ktime_get_ns();

	/*
	 * Non-atomic compare-and-update: acceptable for a diagnostic tool
	 * where a rare race producing a slightly stale max_skb_len is harmless.
	 */
	if (skb_len > v->max_skb_len)
		v->max_skb_len = skb_len;
	v->last_seen_ns = now;

	return 0;
}

char _license[] SEC("license") = "GPL";
