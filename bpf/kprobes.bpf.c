/*
 * bpf/kprobes.bpf.c
 *
 * Kprobe BPF program for post-netfilter ICMP receive counting.
 *
 * Hook: kprobe/icmp_rcv
 *
 * Kernel path for incoming ICMP:
 *   NIC → TC ingress (clsact) → ip_rcv → netfilter INPUT → icmp_rcv
 *
 * icmp_rcv is called AFTER the netfilter INPUT chain. If iptables has a
 * DROP rule for ICMP type 3 code 4 (fragmentation needed), the packet is
 * discarded before icmp_rcv and this counter does NOT increment.
 *
 * Suppression detection signal:
 *   TC ingress count  > 0   (PTB arrived before netfilter)
 *   icmp_rcv_total   == 0   (PTB was dropped by netfilter)
 *   → PTB suppressed by iptables/nft
 *
 *   TC ingress count  > 0   (PTB arrived before netfilter)
 *   icmp_rcv_total   > 0    (PTB reached icmp_rcv — not suppressed)
 *   → PTB delivered normally
 *
 * Scope: this kprobe is attached globally (not per-namespace). In an
 * isolated lab environment (ns1+ns2 only, no other ICMP traffic) the
 * counter reflects only the injected PTBs.
 *
 * Counting all icmp_rcv calls (not filtered by type/code): in our lab
 * test, only ICMP PTBs are injected; no other ICMP traffic is generated.
 * Therefore icmp_rcv_total == number of PTBs that passed netfilter.
 *
 * icmp_send is NOT used here: Day 2 established that icmp_send is not a
 * T symbol on kernel 6.10.14-linuxkit (use tracepoint:net:icmp_send
 * if icmp_send observation is needed in future work).
 *
 * icmp_rcv IS a T symbol on kernel 6.10.14-linuxkit:
 *   grep ' T icmp_rcv$' /proc/kallsyms → confirmed Day 2
 *
 * Attach (via spikes/probe_attach.c C loader or Go cilium/ebpf loader):
 *   The kprobe section name "kprobe/icmp_rcv" tells libbpf which function
 *   to probe. Attach via bpf_program__attach_kprobe().
 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

/*
 * Map: global count of icmp_rcv invocations seen after netfilter.
 * Single-entry ARRAY: key 0 → u64 count.
 */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key,   __u32);
	__type(value, __u64);
} icmp_rcv_total SEC(".maps");

/*
 * kprobe/icmp_rcv — fires every time icmp_rcv() is called in the kernel.
 *
 * No packet parsing: we count every invocation. The caller controls the test
 * environment so only PTBs are delivered to ns1 during the test window.
 *
 * Does not inspect skb content (no struct field access, no CO-RE required).
 * This keeps the verifier proof trivially short and avoids dependence on
 * struct sk_buff layout across kernel versions.
 */
SEC("kprobe/icmp_rcv")
int kprobe_icmp_rcv(struct pt_regs *ctx)
{
	__u32 zero = 0;
	__u64 *total = bpf_map_lookup_elem(&icmp_rcv_total, &zero);
	if (total)
		__sync_fetch_and_add(total, 1);
	return 0;
}

char _license[] SEC("license") = "GPL";
