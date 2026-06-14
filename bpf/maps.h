/* bpf/maps.h
 *
 * BPF map type definitions shared across all vxlan-tracer BPF programs.
 * Included by tc_egress_vxlan0.bpf.c, tc_ingress_eth0.bpf.c, kprobes.bpf.c.
 *
 * NOT YET USED — included here to define the schema before implementation.
 */
#pragma once

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

/* ---- Key and value structs ---- */

struct flow_key {
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8  proto;
    __u8  pad[3];   /* align to 4 bytes */
};

struct flow_val {
    __u64 last_seen_ns;
    __u16 max_pkt_size;   /* inner IP packet size at TC egress vxlan0 */
    __u16 pad;
    __u32 remote_vtep;    /* 0 in v0; populated via bpf_fib_lookup in v1 */
    __u32 vni;            /* 0 in v0; populated via config map in v1 */
    __u32 _reserved;
};

struct ptb_key {
    __u32 ptb_src_ip;   /* IP sending the PTB (remote router or VTEP) */
    __u32 ptb_dst_ip;   /* our underlay IP receiving the PTB */
};

struct ptb_val {
    __u64 first_seen_ns;
    __u16 next_hop_mtu;
    __u16 pad;
    __u32 ptb_count;
};

struct frag_key {
    __u32 vtep_ip;   /* outer IP destination (remote VTEP) */
};

struct frag_val {
    __u64 first_seen_ns;
    __u32 frag_count;
    __u16 orig_outer_len;  /* outer skb->len at ip_do_fragment entry */
    __u16 dev_mtu;         /* dev->mtu that triggered fragmentation */
};

struct config_val {
    __u16 vxlan_port;       /* default 4789 */
    __u16 underlay_ifindex;
    __u32 _reserved;
};

/* ---- Map declarations ---- */

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, struct flow_key);
    __type(value, struct flow_val);
} flow_state SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct ptb_key);
    __type(value, struct ptb_val);
} ptb_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} ptb_processed SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, struct frag_key);
    __type(value, struct frag_val);
} frag_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct config_val);
} config SEC(".maps");
