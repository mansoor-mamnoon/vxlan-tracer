/*
 * bpf/frag_kprobes.bpf.c
 *
 * Kprobe BPF program for counting ip_do_fragment invocations.
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
 * This kprobe counts every ip_do_fragment call. In the initial commit-2
 * implementation only struct frag_val.total is populated; skb->len field
 * reads (max_skb_len, last_seen_ns) are added in commit 7 once the
 * count-only path is proven against a live kernel and the argument position
 * for skb (PT_REGS_PARM3) is confirmed on the target arch.
 *
 * ip_do_fragment signature (kernel ≥ 4.20):
 *   int ip_do_fragment(struct net *net, struct sock *sk, struct sk_buff *skb,
 *                      int (*output)(...))
 *   arg1 = net  (PT_REGS_PARM1)
 *   arg2 = sk   (PT_REGS_PARM2)
 *   arg3 = skb  (PT_REGS_PARM3) ← used in commit 7
 *   arg4 = fn   (PT_REGS_PARM4)
 *
 * Scope limitation: this hook fires for ALL IP fragmentation on the host,
 * not only VXLAN outer packets. In the lab topology (only VXLAN traffic)
 * this is equivalent. A per-device filter is deferred.
 */

#include <linux/bpf.h>
#include <linux/ptrace.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#include "maps.h"

/*
 * Map: global count of ip_do_fragment invocations.
 * Single-entry ARRAY: key 0 → struct frag_val.
 * In this commit only frag_val.total is updated; the remaining fields
 * (last_seen_ns, max_skb_len) remain zero until commit 7.
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
	__u32 zero = 0;
	struct frag_val *v = bpf_map_lookup_elem(&frag_events_total, &zero);
	if (v)
		__sync_fetch_and_add(&v->total, 1);
	return 0;
}

char _license[] SEC("license") = "GPL";
