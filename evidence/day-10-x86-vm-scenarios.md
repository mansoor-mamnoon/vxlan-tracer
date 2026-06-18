# Day 10 x86_64 scenario validation — GitHub Actions run 2

**Date:** 2026-06-18
**Run:** 27743797987 (commit b66a4c4)
**Environment:** GitHub Actions ubuntu-22.04, Azure westus region
**Kernel:** 6.8.0-1052-azure
**Architecture:** x86_64 (amd64)
**Distro:** Ubuntu 22.04.5 LTS
**BPF target arch:** __TARGET_ARCH_x86 (PT_REGS_PARM1 = ctx->di, x86_64 rdi register)
**BTF:** /sys/kernel/btf/vmlinux, 6020051 bytes
**bpftool:** v7.4.0

---

## Result: 5/5 PASS

```
[PASS] verdict=VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=PTB_DELIVERED
[PASS] verdict=PTB_SUPPRESSED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
Results: 5 passed, 0 failed
```

This is the first run of vxlan-tracer on a real x86_64 kernel. All five verdicts are
correct and JSON fields are consistent with aarch64 results.

---

## BPF compilation (first successful x86_64 compile + load)

```
  prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=x86_64
  CC  bpf/tc_ingress_eth0.bpf.o
clang -O2 -g -target bpf -I/usr/include -I/usr/include/x86_64-linux-gnu -D__x86_64__ \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o bpf/tc_ingress_eth0.bpf.o
  CC  bpf/tc_egress_vxlan0.bpf.o
  CC  bpf/kprobes.bpf.o
clang ... -D__TARGET_ARCH_x86 -c bpf/kprobes.bpf.c -o bpf/kprobes.bpf.o
  CC  bpf/frag_kprobes.bpf.o
clang ... -D__TARGET_ARCH_x86 -c bpf/frag_kprobes.bpf.c -o bpf/frag_kprobes.bpf.o
BPF build complete.
-rw-r--r-- 1 root root 8.4K bpf/frag_kprobes.bpf.o
-rw-r--r-- 1 root root 8.6K bpf/kprobes.bpf.o
-rw-r--r-- 1 root root  17K bpf/tc_egress_vxlan0.bpf.o
-rw-r--r-- 1 root root  18K bpf/tc_ingress_eth0.bpf.o
```

All four BPF objects compiled with `-D__x86_64__` (glibc stubs fix) and
`-D__TARGET_ARCH_x86` (kprobe PT_REGS register mapping).

---

## Go binary

```
dist/vxlan-tracer: ELF 64-bit LSB executable, x86-64, version 1 (SYSV),
  dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, Go BuildID=...,
  with debug_info, not stripped
size: 4.9M
```

Native x86_64 binary, built with `make build` on the runner.

---

## Unit tests

```
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap	0.005s
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/diag	0.004s
```

All packages pass. (cmd, loader, output, spikes: no test files.)

---

## Preflight (new capability-probing version)

```
  PASS  Linux
  PASS  Kernel 6.8.0-1052-azure >= 5.15
  PASS  Running as root (UID 0)
  WARN  unprivileged_bpf_disabled=2
  WARN  perf_event_paranoid=4
  PASS  ip netns add/del works (CAP_NET_ADMIN present)
  FAIL [ENVIRONMENT]  ip link add dummy failed even as root
  PASS  BPF ARRAY map create via bpftool works (CAP_BPF present)
  PASS  /sys/kernel/btf/vmlinux exists (6020051 bytes)
  PASS  bpffs mounted (/sys/fs/bpf)
  PASS  ip (/usr/sbin/ip)
  PASS  iptables (/usr/sbin/iptables)
  PASS  python3 (/usr/bin/python3)
  PASS  nsenter (/usr/bin/nsenter)
  PASS  clang (Ubuntu clang version 14.0.0-1ubuntu1.1)
  PASS  go (...)
  PASS  make (GNU Make 4.3)
  PASS  bpftool (bpftool v7.4.0)
  PASS  ping (/usr/bin/ping)
  PASS  scapy 2.7.0
  PASS  /usr/include/bpf/bpf_helpers.h found
  PASS  /usr/include/linux/bpf.h found
  INFO  arch=x86_64 → BPF define: -D__TARGET_ARCH_x86
  PASS  arch include path: /usr/include/x86_64-linux-gnu (exists)
  PASS  ip_do_fragment is a T symbol (kprobeable)
  PASS  icmp_rcv is a T symbol (kprobeable)
  PASS  ip netns list works

PASS: 23  WARN: 2  FAIL: 1
RESULT: FAIL (continue-on-error in workflow)
```

**Key observation:** The preflight reports FAIL because `ip link add dummy` fails
at the root/global network namespace level. However, the scenario suite PASSES
(5/5). This is because the scenario setup creates veth pairs inside isolated
network namespaces (`ip netns exec ns1 ...`), not in the global namespace. The
preflight's clsact qdisc probe uses a global dummy interface, which triggers the
runner restriction. The actual TC operations are inside netns — which is allowed.

This reveals a gap in the preflight probe: a FAIL on the clsact probe does NOT
block scenario execution. The probe should be categorized as an advisory warning
for shared-runner environments, not a hard blocker.

---

## Scenario JSON outputs

### Scenario 1: VXLAN_MTU_MISCONFIGURATION (small traffic, no fragmentation observed)

```json
{
  "verdict": "VXLAN_MTU_MISCONFIGURATION",
  "message": "No PTBs, fragmentation events, or oversized traffic were observed during this run, but the overlay MTU (1450) exceeds the safe value for the underlay MTU (1400) by 100 byte(s). This is a static configuration risk: traffic large enough to use the full overlay MTU would trigger either fragmentation or a PTB, depending on the DF bit.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 118
}
```

### Scenario 2: VXLAN_FRAGMENTATION_OBSERVED

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present — these two signals together are consistent with VXLAN outer packets triggering ip_do_fragment. Note: ip_do_fragment is a global kernel function and may include non-VXLAN fragmentation events on a busy host. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.",
  "fragmentation_scope": "global_corroborated",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

### Scenario 3: PTB_DELIVERED

```json
{
  "verdict": "PTB_DELIVERED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

### Scenario 4: PTB_SUPPRESSED

```json
{
  "verdict": "PTB_SUPPRESSED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

### Scenario 5: Second-run idempotency

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

Second run produces identical verdict after route cache flush — idempotent on 6.8.0-1052-azure x86_64.

---

## Comparison with aarch64 results

| Field | x86_64 (6.8.0-azure) | aarch64 (5.15.0-181) | aarch64 (6.10.14-linuxkit) |
|-------|----------------------|----------------------|---------------------------|
| frag_events_total | 6 | 6 | 6 |
| frag_max_skb_len | 1438 | 1438 | 1438 |
| max_outer_ip_len | 1438 | 1438 | 1438 |
| fragmentation_scope | global_corroborated | global_corroborated | global_corroborated |
| ptb_ingress_total (PTB_DELIVERED) | 5 | 5 | 5 |
| icmp_rcv_total (PTB_DELIVERED) | 5 | 5 | 5 |
| ptb_ingress_total (PTB_SUPPRESSED) | 5 | 5 | 5 |
| icmp_rcv_total (PTB_SUPPRESSED) | 0 | 0 | 0 |

All fields identical. PT_REGS_PARM1 (x86 rdi register) resolves ip_do_fragment's
`skb` argument correctly — same skb->len values as aarch64.

---

## What this run proves

1. **`__TARGET_ARCH_x86` code path works at runtime** — the x86_64 kprobe
   PT_REGS_PARM1 convention (ctx->di = rdi) resolves ip_do_fragment's skb
   argument correctly. frag_max_skb_len=1438 confirms skb->len is read via
   CO-RE correctly on x86_64.
2. **All five verdicts are reachable on x86_64 kernel 6.8.0-1052-azure.**
3. **BPF verifier accepts all four programs on x86_64 6.8.** No verifier errors.
4. **clsact qdisc TC attach works inside network namespaces on this runner**,
   even though global dummy interface creation is blocked.
5. **CO-RE BTF resolution works on x86_64 6.8.0** — vmlinux BTF (6020051 bytes)
   resolves all struct offsets for sk_buff, icmphdr.
6. **ip route flush cache idempotency works on x86_64.**
7. **github-hosted ubuntu-22.04 runners can run full e2e scenario suite** for
   vxlan-tracer when given `sudo` and network namespace access.

## What remains unproven

- bpf_get_netns_cookie on x86_64 (expected UNSUPPORTED, not retested)
- Production Kubernetes environments (Flannel, Calico) on x86_64
- Other x86_64 kernel versions (5.15.x LTS, 6.1.x, 6.5.x)
- perf_event_paranoid=4 effect: this was WARN in preflight, but kprobes
  attached successfully with sudo — consistent with root bypassing paranoia level
