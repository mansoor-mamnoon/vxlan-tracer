/*
 * tests/fixtures/tc_ingress_missing_config.bpf.c
 *
 * Intentionally stale TC ingress BPF object for integration testing.
 *
 * Has the same ELF section ("tc") and program name ("tc_ingress_count_ptb")
 * as the production bpf/tc_ingress_eth0.bpf.c, but deliberately omits the
 * vxlan_config ARRAY map.  Loading this object via the production Go loader
 * must produce the following error:
 *
 *   vxlan_config map missing from tc_ingress object — likely stale BPF object;
 *   run: make clean-bpf && make bpf
 *
 * Used by: scripts/test-stale-bpf-object.sh
 *
 * DO NOT use in production. This object represents a pre-Day-11 state where
 * the vxlan_config map did not exist.
 */

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <linux/pkt_cls.h>

/* Intentionally absent: vxlan_config, ptb_ingress_counts, ptb_ingress_total */

SEC("tc")
int tc_ingress_count_ptb(struct __sk_buff *skb)
{
	return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
