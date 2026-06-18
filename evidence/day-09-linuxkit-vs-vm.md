# Day 9 — LinuxKit 6.10.14 vs Ubuntu 22.04 5.15.0-181 comparison

**Date:** 2026-06-17

This document compares behavior between the two test environments as of Day 9.
Both are aarch64. No x86_64 data is available yet.

Do not generalize the "no difference" findings to x86_64 or other distros.
These are two data points on one architecture.

## Environment summary

| | Docker Desktop LinuxKit | Lima VM Ubuntu 22.04 |
|-|------------------------|----------------------|
| Kernel | 6.10.14-linuxkit | 5.15.0-181-generic |
| Distro | N/A (LinuxKit = Docker's custom kernel) | Ubuntu 22.04.5 LTS |
| Architecture | aarch64 | aarch64 |
| BTF size | Not measured | 5.8 MB (/sys/kernel/btf/vmlinux) |
| bpftool | Mismatched wrapper (v5.15.199 on 6.10 kernel) | Kernel-matched (v5.15.199 on 5.15 kernel) |
| Environment | `--privileged` Docker container | Real VM (macOS VZ hypervisor) |

## ip_do_fragment symbol

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| `/proc/kallsyms` T symbol | YES | YES |
| kprobe attachable | YES (cilium/ebpf link.Kprobe) | YES (confirmed via scenario run) |
| frag_events_total per 3 oversized pings | 6 | 6 |

**Finding:** ip_do_fragment is a kprobeable T symbol on both kernels. Firing rate is identical (2 per ping, both directions).

## icmp_rcv symbol

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| `/proc/kallsyms` T symbol | YES | YES |
| kprobe attachable | YES | YES (confirmed via PTB scenarios) |
| PTB delivered count (5 injected) | 5 | 5 |
| PTB suppressed count (iptables DROP) | 0 | 0 |

**Finding:** icmp_rcv kprobe behaves identically on both kernels.

## BTF / CO-RE

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| /sys/kernel/btf/vmlinux | Present | Present (5.8 MB) |
| skb->len CO-RE relocation | Resolved | Resolved |
| frag_max_skb_len at ip_do_fragment | 1438 (outer IP) | 1438 (outer IP) |
| skb->network_header inconsistency | Confirmed (Day 8 spike) | Not retested (see day-09-vm-helper-scope.md) |

**Finding:** CO-RE BTF relocation for skb->len resolves correctly on 5.15.0-181-generic. Both kernels return 1438 at ip_do_fragment entry when the route cache is clean, consistent with the outer IP packet length.

## bpf_get_netns_cookie availability

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| kprobe program type | NOT AVAILABLE (verifier error) | Retested in day-09-vm-helper-scope.md |
| sched_cls program type | NOT AVAILABLE (verifier error) | Retested in day-09-vm-helper-scope.md |

See `evidence/day-09-vm-helper-scope.md` for the 5.15 result.

## Route / PMTU cache

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| PMTU cache populated after large ping | YES (mtu 1350 expires 597sec) | YES (confirmed: second run without flush gives route cache state) |
| ip route flush cache effective | YES (exit 0, cache empty) | YES (second-run scenario: global_corroborated after flush) |
| frag_max_skb_len before flush | 1438 | 1438 |
| frag_max_skb_len after flush | 1438 (fresh outer packets) | 1438 (same) |

**Finding:** Route/PMTU cache behavior is identical. `ip route flush cache` is effective on 5.15.0-181-generic.

## Two-signal corroboration

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| fragmentation_scope: global_corroborated | YES (clean run) | YES (clean run) |
| fragmentation_scope after second run with flush | global_corroborated | global_corroborated |
| max_outer_ip_len | 1438 | 1438 |

**Finding:** Two-signal corroboration fires identically on both kernels.

## TC egress BPF (tc_egress_vxlan0)

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| Filter attaches (jited) | YES | YES |
| max_outer_ip_len for oversized ping | 1438 | 1438 |
| max_outer_ip_len for small ping | 118 | 118 |
| ARRAY map pinning under /sys/fs/bpf | YES | YES |

## Verdict stability

All five verdicts are identical on both kernels when tested with the same lab topology:

| Scenario | 6.10.14-linuxkit | 5.15.0-181-generic |
|----------|-----------------|-------------------|
| healthy_small | VXLAN_MTU_MISCONFIGURATION | VXLAN_MTU_MISCONFIGURATION |
| fragmentation | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED |
| ptb_delivered | PTB_DELIVERED | PTB_DELIVERED |
| ptb_suppressed | PTB_SUPPRESSED | PTB_SUPPRESSED |
| fragmentation (2nd run) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED |

## What this comparison does and does not prove

**Proves:**
- The tool produces consistent verdicts across two aarch64 Linux kernels (5.15 LTS and 6.10 linuxkit)
- CO-RE BTF resolution is correct on 5.15.0-181-generic
- ip_do_fragment and icmp_rcv kprobes work on both kernels
- Route cache behavior is consistent

**Does not prove:**
- x86_64 behavior (different architecture, potentially different register conventions for PT_REGS_PARM1)
- Other Ubuntu versions or distros
- Kernels 5.10, 6.1, 6.8 (not tested)
- Production VXLAN environments (Flannel, Calico, Cilium with real pods)
- Behavior under load (all tests use very light traffic)
