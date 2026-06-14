# evidence/day-03-attach.md

TC BPF attachment results from Day 3.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## tc_ingress_eth0.bpf.c — attached to veth1 ingress in ns1

### Attach commands

```sh
# Add clsact qdisc (required for TC BPF with both ingress and egress hooks)
ip netns exec ns1 tc qdisc add dev veth1 clsact
# Exit: 0

# Attach BPF program to ingress
ip netns exec ns1 tc filter add dev veth1 ingress bpf da \
    obj /tmp/tc_ingress_eth0.bpf.o sec tc
# Exit: 0
```

### Filter verification

```
$ ip netns exec ns1 tc filter show dev veth1 ingress

filter protocol all pref 49152 bpf chain 0
filter protocol all pref 49152 bpf chain 0 handle 0x1 tc_ingress_eth0.bpf.o:[tc] \
    direct-action not_in_hw id 112 tag 20bd2d524d2b4592 jited
```

Key fields:
- `direct-action`: program return value used as TC action (TC_ACT_OK = pass)
- `not_in_hw`: hardware offload not attempted (expected for veth)
- `id 112`: kernel-assigned BPF program ID
- `tag 20bd2d524d2b4592`: SHA hash of the BPF bytecode
- `jited`: program was JIT-compiled by the kernel ← verifier accepted and compiled it

### bpftool prog list

```
112: sched_cls  name tc_ingress_coun  tag 20bd2d524d2b4592  gpl
```

Program type `sched_cls` (TC classifier) confirms TC attachment is correct.
Name `tc_ingress_coun` is the first 15 chars of the function `tc_ingress_count_ptb`.

### bpftool map list (maps created by the program)

```
60: hash   name ptb_ingress_cou  flags 0x0   ← ptb_ingress_counts HASH
61: array  name ptb_ingress_tot  flags 0x0   ← ptb_ingress_total  ARRAY
```

Both maps are live and bound to the loaded program.

### What this proves

1. `tc_ingress_eth0.bpf.c` compiles to a valid BPF ELF.
2. The BPF verifier accepted the program (prerequisite for `jited`).
3. JIT compilation succeeded.
4. The program is attached to `veth1` ingress in `ns1` and will run on every
   packet entering that interface before netfilter.
5. The maps `ptb_ingress_counts` and `ptb_ingress_total` are created and will
   accumulate counts.

### What remains to be shown

- Map values actually increment when PTBs arrive (Commit 6).
- tc_egress_vxlan0 attachment (Commits 8-9).
