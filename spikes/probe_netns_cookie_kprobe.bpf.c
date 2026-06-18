/*
 * spikes/probe_netns_cookie_kprobe.bpf.c
 *
 * Minimal kprobe BPF program that calls bpf_get_netns_cookie().
 * Used to test whether the helper is permitted in BPF_PROG_TYPE_KPROBE
 * on the current kernel.
 *
 * If bpf_get_netns_cookie is not available for kprobes, the verifier
 * will reject the program with:
 *   "unknown func bpf_get_netns_cookie#NN"
 * or:
 *   "helper call is not allowed in probe"
 *
 * bpf_get_netns_cookie(NULL) returns the cookie for the current netns.
 * bpf_get_netns_cookie(ctx)  returns the cookie for the netns of ctx->sk
 * (only meaningful in socket programs; passing ctx from a kprobe is UB
 * and the verifier may reject it — we test NULL first).
 *
 * Compile:
 *   clang -O2 -g -target bpf -D__TARGET_ARCH_arm64 \
 *     -I/usr/include -I/usr/include/aarch64-linux-gnu \
 *     -c spikes/probe_netns_cookie_kprobe.bpf.c \
 *     -o /tmp/probe_netns_cookie_kprobe.bpf.o
 *
 * Load test (requires bpftool):
 *   bpftool prog load /tmp/probe_netns_cookie_kprobe.bpf.o /sys/fs/bpf/probe_kprobe \
 *     type kprobe 2>&1; echo "exit=$?"
 *   bpftool prog load /tmp/probe_netns_cookie_kprobe.bpf.o /sys/fs/bpf/probe_kprobe \
 *     type kprobe pinmaps /sys/fs/bpf/probe_maps 2>&1; echo "exit=$?"
 */

#include <linux/bpf.h>
#include <linux/ptrace.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

/* Store the cookie so the verifier cannot optimize the call away. */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} cookie_result SEC(".maps");

SEC("kprobe/ip_do_fragment")
int probe_netns_cookie_kprobe(struct pt_regs *ctx)
{
	__u32 zero = 0;
	__u64 *slot = bpf_map_lookup_elem(&cookie_result, &zero);
	if (!slot)
		return 0;

	/*
	 * bpf_get_netns_cookie(NULL): returns the cookie for the init_net
	 * or the current task's network namespace, depending on the kernel
	 * implementation. Passing NULL avoids requiring a socket context.
	 */
	*slot = bpf_get_netns_cookie(NULL);
	return 0;
}

char _license[] SEC("license") = "GPL";
