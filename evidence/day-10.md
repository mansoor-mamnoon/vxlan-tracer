# Day 10 synthesis — cross-architecture v0 validated

**Date:** 2026-06-18
**Primary goal:** Validate vxlan-tracer on a real x86_64 Linux kernel.

---

## Primary success condition met

> "Run the existing scenario suite on at least one x86_64 kernel and record:
> uname -a, architecture, distro, kernel version, BTF availability, BPF helper
> behavior, whether all scenarios pass, whether any verdicts differ."

**Result: MET.**

x86_64 environment used: GitHub Actions ubuntu-22.04 runner (Azure-hosted)

```
uname -a:
  Linux runnervmqtt2i 6.8.0-1052-azure #58~22.04.1-Ubuntu SMP Thu Mar 26 05:02:21 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux

Architecture: x86_64
Distro: Ubuntu 22.04.5 LTS
Kernel: 6.8.0-1052-azure (Azure infrastructure kernel)
BTF: /sys/kernel/btf/vmlinux (6020051 bytes)
```

5/5 scenarios pass. All verdicts and JSON field values identical to aarch64.

---

## Commits and work

### Commit 1 — GitHub Actions workflow (f23e9b7)

`.github/workflows/x86-smoke.yml`: x86_64 capability probe workflow.
Runs on ubuntu-22.04 (x86_64). Steps: capture env, install deps, mount bpffs,
preflight, BPF compile, Go build, unit tests, attempt scenario suite.

### Commit 2 — preflight capability checks (cb468f1)

`scripts/preflight.sh`: added live capability probes:
- CAP_NET_ADMIN: ip netns add/del probe (PRIVILEGE vs ENVIRONMENT categories)
- TC BPF: ip link add dummy + tc qdisc add clsact probe
- CAP_BPF: bpftool map create ARRAY probe (direct BPF syscall test)
- Sysctl checks: unprivileged_bpf_disabled, perf_event_paranoid
- Architecture check: x86_64 vs aarch64 include paths
- Failure categories: [DEPENDENCY] [PRIVILEGE] [KERNEL] [ENVIRONMENT]
- New check count: 26+ (was 20 in Day 9)

### Commit 3 — x86_64 stubs fix + run 1 evidence (b66a4c4)

Actions run 1 (27743347938) failed at BPF compile with:
  `fatal error: 'gnu/stubs-32.h' file not found`

Root cause: `clang -target bpf` does not define `__x86_64__`; glibc stubs.h
requests stubs-32.h (gcc-multilib) which is absent.

Fix: add `-D__x86_64__` to `_ARCH_INC` for x86_64 in Makefile.
Belt-and-suspenders: add `gcc-multilib` to workflow install.

Run 1 evidence documented: kernel 6.8.0-1052-azure (not 5.15.x as expected),
BTF present, ip_do_fragment T symbol confirmed, preflight 20/20 PASS (old version).

### Commit 4 — cloud validation guide + arch comparison (41c41c7)

`docs/x86-cloud-validation.md`: AWS/GCP/Azure step-by-step, evidence template,
security group notes, cleanup commands.

`evidence/day-10-arch-comparison.md`: PT_REGS_PARM1 register differences
(aarch64 regs[0] vs x86_64 rdi), -D__x86_64__ stubs fix, CO-RE behavior
confirmed identical on both architectures.

### Commit 5 — 5/5 PASS on x86_64 (c4cb7a5)

Actions run 2 (27743797987) succeeded:
```
Results: 5 passed, 0 failed
```
All five verdict paths correct on 6.8.0-1052-azure x86_64.
frag_max_skb_len=1438, max_outer_ip_len=1438, ptb_ingress_total=5,
icmp_rcv_total=5/0 — all identical to aarch64.

Kernel matrix entry 3 added with confirmed PASS.

### Commit 6 — Makefile arch detection hardening (d065fd7)

`bpf-check`: explicit FAIL with message for unsupported architectures (not aarch64/x86_64).
`prereqs OK` line now prints `bpf_target=` so the selected PT_REGS define is visible.

### Commit 7 — test-results + hook-findings (34db15b)

`evidence/test-results.md`: Day 10 x86_64 run appended.
`evidence/hook-findings.md`: findings 32-36 + updated confidence table (3 kernels, 2 archs).

### Commit 8 — README (d223cca)

Status updated: "cross-architecture v0 prototype — validated on three Linux kernels
across two architectures." x86_64 removed from "not proven" list.
Kernel matrix table: entry 3 added.

### Commit 9 — roadmap + Day 10 synthesis (this commit)

`docs/roadmap.md`: Day 10 items checked off.
`evidence/day-10.md`: this file.

---

## Is vxlan-tracer now cross-architecture?

**Yes.** Three kernel test results across two architectures:
1. 6.10.14-linuxkit aarch64 (Docker Desktop) — 5/5 pass
2. 5.15.0-181-generic aarch64 (Ubuntu 22.04 Lima VM) — 5/5 pass
3. 6.8.0-1052-azure x86_64 (GitHub Actions) — 5/5 pass

All three environments produce identical verdicts. No behavioral differences
between architectures. The PT_REGS_PARM1 register convention difference
(aarch64 vs x86_64) is handled correctly by the `-D__TARGET_ARCH_*` flag.

---

## What is now proven

1. 5/5 scenario suite passes on three kernels: 6.10.14-linuxkit, 5.15.0-181-generic, 6.8.0-1052-azure
2. All verdict types and JSON fields are consistent across all three kernels and two architectures
3. PT_REGS_PARM1 x86_64 convention (ctx->di = rdi) resolves ip_do_fragment's skb correctly
4. CO-RE BTF resolution is architecture-independent (identical skb->len values)
5. BPF verifier accepts all four programs on all three kernels
6. bpf_get_netns_cookie UNSUPPORTED on kprobe/sched_cls on aarch64 kernels (verified)
7. ip_do_fragment header parsing spike confirmed on all kernels; two-signal strategy valid
8. ip route flush cache effective on all three kernels (idempotency proven)
9. GitHub Actions ubuntu-22.04 runner provides a working BPF/kprobes/netns environment
10. x86_64 BPF compile requires -D__x86_64__ — documented and fixed in Makefile
11. preflight now distinguishes 4 failure categories with live capability probes
12. clsact qdisc works inside network namespaces on GitHub Actions runners (global netns blocked)
13. perf_event_paranoid=4 does not block kprobe attachment as root

---

## What remains unproven

- x86_64 kernel versions other than 6.8.0-1052-azure (5.15.x, 6.1.x, 6.5.x)
- bpf_get_netns_cookie UNSUPPORTED on x86_64 (expected same; not retested)
- Production Kubernetes environments (Flannel, Calico, Cilium) on either arch
- VXLAN-specific scoping of ip_do_fragment (still global on all tested kernels)
- bpftrace on a kernel with working bpftrace (not tried since Day 8)

---

## Day 10 answers to the primary questions

**Q: Can the x86_64 BPF code path compile?**
A: Yes, with -D__x86_64__ fix. (Without it: gnu/stubs-32.h error.)

**Q: Does the x86_64 kprobe PT_REGS_PARM1 resolve ip_do_fragment's skb?**
A: Yes. frag_max_skb_len=1438 matches aarch64 exactly.

**Q: Do all five verdicts work on x86_64?**
A: Yes. Identical to aarch64 in both verdict type and JSON field values.

**Q: Is the tool now cross-architecture?**
A: Yes. v0 is validated on two architectures and three kernels.
