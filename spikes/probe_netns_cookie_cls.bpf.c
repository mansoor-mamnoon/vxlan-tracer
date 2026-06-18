/*
 * spikes/probe_netns_cookie_cls.bpf.c
 *
 * Minimal sched_cls (TC) BPF program that calls bpf_get_netns_cookie().
 * Used to test whether the helper is permitted in BPF_PROG_TYPE_SCHED_CLS
 * on the current kernel.
 *
 * In TC sched_cls programs, the context is struct __sk_buff*.
 * bpf_get_netns_cookie(skb) should return the netns cookie for the
 * network namespace of the socket/device associated with the skb.
 *
 * Compile:
 *   clang -O2 -g -target bpf \
 *     -I/usr/include -I/usr/include/aarch64-linux-gnu \
 *     -c spikes/probe_netns_cookie_cls.bpf.c \
 *     -o /tmp/probe_netns_cookie_cls.bpf.o
 *
 * Load test:
 *   bpftool prog load /tmp/probe_netns_cookie_cls.bpf.o /sys/fs/bpf/probe_cls \
 *     type sched_cls 2>&1; echo "exit=$?"
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} cookie_result_cls SEC(".maps");

SEC("tc")
int probe_netns_cookie_cls(struct __sk_buff *skb)
{
	__u32 zero = 0;
	__u64 *slot = bpf_map_lookup_elem(&cookie_result_cls, &zero);
	if (!slot)
		return TC_ACT_OK;

	/*
	 * bpf_get_netns_cookie(skb): returns the cookie for the netns of
	 * the socket/device associated with this sk_buff. In a TC program
	 * attached to veth1 in ns1, this should return ns1's cookie.
	 */
	*slot = bpf_get_netns_cookie(skb);
	return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
