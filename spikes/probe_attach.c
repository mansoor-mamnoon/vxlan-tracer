/*
 * spikes/probe_attach.c
 *
 * SPIKE — not production code.
 *
 * Minimal libbpf loader for kprobes.bpf.o. Loads the BPF object, attaches
 * kprobe/icmp_rcv, sleeps for a specified duration (default 30 seconds),
 * then reads and prints the icmp_rcv_total counter before exiting.
 *
 * libbpf takes care of attaching and detaching the kprobe. When the program
 * exits (or the link is destroyed), the kprobe is automatically removed.
 *
 * Compile (on Linux):
 *   gcc -O2 -o /tmp/probe_attach spikes/probe_attach.c -lbpf
 *
 * Usage:
 *   /tmp/probe_attach <bpf_obj> [duration_seconds]
 *   /tmp/probe_attach /tmp/kprobes.bpf.o 30
 *
 * While running, inject synthetic PTBs from ns2 using inject_ptb.py.
 * The counter increments for every icmp_rcv call that occurs after netfilter.
 * If an iptables DROP rule is active for ICMP PTBs, icmp_rcv is never called
 * and the counter stays 0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>

int main(int argc, char *argv[])
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <bpf_obj> [duration_seconds]\n", argv[0]);
		return 1;
	}

	const char *obj_path = argv[1];
	int duration = (argc >= 3) ? atoi(argv[2]) : 30;

	struct bpf_object *obj = bpf_object__open(obj_path);
	if (!obj) {
		fprintf(stderr, "bpf_object__open(%s) failed: %s\n",
			obj_path, strerror(errno));
		return 1;
	}

	if (bpf_object__load(obj)) {
		fprintf(stderr, "bpf_object__load failed\n");
		bpf_object__close(obj);
		return 1;
	}

	struct bpf_program *prog =
		bpf_object__find_program_by_name(obj, "kprobe_icmp_rcv");
	if (!prog) {
		fprintf(stderr, "program 'kprobe_icmp_rcv' not found in %s\n", obj_path);
		bpf_object__close(obj);
		return 1;
	}

	/* Attach kprobe to icmp_rcv (false = entry probe, not return probe) */
	struct bpf_link *link =
		bpf_program__attach_kprobe(prog, false, "icmp_rcv");
	if (!link) {
		fprintf(stderr, "bpf_program__attach_kprobe(icmp_rcv) failed: %s\n",
			strerror(errno));
		bpf_object__close(obj);
		return 1;
	}

	struct bpf_map *map =
		bpf_object__find_map_by_name(obj, "icmp_rcv_total");
	if (!map) {
		fprintf(stderr, "map 'icmp_rcv_total' not found\n");
		bpf_link__destroy(link);
		bpf_object__close(obj);
		return 1;
	}
	int map_fd = bpf_map__fd(map);

	__u32 key = 0;
	__u64 val = 0;
	bpf_map_lookup_elem(map_fd, &key, &val);
	printf("probe_attach: kprobe/icmp_rcv attached to kernel icmp_rcv\n");
	printf("probe_attach: icmp_rcv_total at attach = %llu\n", (unsigned long long)val);
	printf("probe_attach: running for %d seconds...\n", duration);
	fflush(stdout);

	sleep(duration);

	val = 0;
	bpf_map_lookup_elem(map_fd, &key, &val);
	printf("probe_attach: icmp_rcv_total at detach = %llu\n", (unsigned long long)val);
	fflush(stdout);

	bpf_link__destroy(link);
	bpf_object__close(obj);
	return 0;
}
