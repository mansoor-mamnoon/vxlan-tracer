# Day 9 synthesis — cross-environment v0 prototype

**Date:** 2026-06-17–18
**Primary goal:** Validate vxlan-tracer on a real Linux VM outside Docker Desktop LinuxKit.

---

## Primary success condition met

> "Run the existing scenario suite on at least one real Linux VM and record:
> actual uname -a, architecture, distro, kernel version, BTF availability,
> BPF helper behavior, whether all scenarios pass, whether any verdicts differ."

**Result: MET.**

Real VM used: Lima (macOS VZ hypervisor, Apple Silicon host)

```
uname -a:
  Linux lima-vxlan-test 5.15.0-181-generic #191-Ubuntu SMP Fri May 22 19:27:05 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux

Distro: Ubuntu 22.04.5 LTS (Jammy Jellyfish)
Architecture: aarch64
Kernel: 5.15.0-181-generic
BTF: /sys/kernel/btf/vmlinux (5.8 MB) — present
```

5/5 scenarios pass. All verdicts identical to linuxkit.

---

## Commits and work

### Commit 1 — VM validation guide (0770da9)

`docs/vm-validation.md`: step-by-step Ubuntu 22.04/24.04 setup, evidence checklist,
Lima quick start, cloud VM security group notes, expected vs linuxkit differences.

### Commit 2 — preflight.sh + VM-friendly scenario runner (90ca8c1)

`scripts/preflight.sh`: 20 checks (OS, kernel version, root, BTF, bpffs, required
commands, libbpf headers, kernel symbols, scapy). PASS/WARN/FAIL per check.

`scripts/run-scenarios.sh`: added preflight section — BPF_DIR existence, all 4 BPF
objects present, required commands, scapy, bpffs, BTF. Clear error messages with
install hints.

`Makefile`: added `preflight` target.

### Commit 3 — preflight 20/20 PASS on Lima VM (a691984)

`evidence/day-09-vm-preflight.md`: first preflight on 5.15.0-181-generic.
20/20 PASS. ip_do_fragment and icmp_rcv confirmed T symbols. BTF present.
bpftool kernel-matched (v5.15.199 on 5.15 kernel — better than linuxkit).

### Commit 4 — unit tests + BPF compile + Go build on VM (63dad92)

`evidence/day-09-vm-env.md`: all four BPF objects compile on 5.15.0-181-generic
with clang 14. 14 unit tests pass. Native Go binary builds (4.8M ELF aarch64).

Bug fixed: `bpf/frag_kprobes.bpf.o` was missing from the `make bpf` Makefile target.
Only compiled inline in the Docker `scenarios` target previously. Fixed with a
proper `bpf/frag_kprobes.bpf.o: bpf/frag_kprobes.bpf.c` rule.

### Commit 5 — 5/5 scenario suite PASS on VM (ea2f244)

`evidence/day-09-vm-scenarios.md`: full scenario run output including JSON for all five
scenarios. All pass. frag_events_total=6, frag_max_skb_len=1438, max_outer_ip_len=1438,
fragmentation_scope=global_corroborated — identical to linuxkit.

### Commit 6 — LinuxKit vs VM comparison (b1eb4a9)

`evidence/day-09-linuxkit-vs-vm.md`: systematic comparison of all behaviors
between 6.10.14-linuxkit and 5.15.0-181-generic. No behavioral differences found
in tested scenarios. x86_64 remains as next target.

### Commit 7 — helper/scoping spike retest on VM (e5ce0c6)

`evidence/day-09-vm-helper-scope.md`:

bpf_get_netns_cookie: UNSUPPORTED on 5.15.0-181-generic (kprobe and sched_cls).
Error: "unknown func bpf_get_netns_cookie#122" (different wording than linuxkit's
"program of this type cannot use helper #122"; same practical result).

Header parsing spike: skb->network_header points to inner IP (ip_proto=1, ICMP)
even on first run — more severe inconsistency than linuxkit (which sometimes
showed outer IP on first run). Two-signal strategy confirmed and strengthened.

### Commit 8 — kernel matrix updated (bcb3c15)

`docs/kernel-matrix.md`: Entry 2 added with full details for 5.15.0-181-generic.
Target matrix updated: x86_64 now highest priority (both current entries are aarch64).

### Commit 9 — README updated (7bc9043)

Status: "cross-environment v0 prototype — validated on two Linux kernels".
What is proven/not proven updated for Day 9. Validated kernel matrix table added.

### Commit 10 — Day 9 synthesis (this commit)

Files: `evidence/day-09.md`, `evidence/test-results.md`, `evidence/hook-findings.md`,
`docs/roadmap.md`.

---

## Is vxlan-tracer still LinuxKit-only or now cross-environment?

**Cross-environment.** Two real kernel test results:
1. 6.10.14-linuxkit aarch64 (Docker Desktop) — 5/5 pass
2. 5.15.0-181-generic aarch64 (Ubuntu 22.04 Lima VM) — 5/5 pass

Both environments produce identical verdicts. No behavioral differences observed.

The credibility gap "the tool has not been validated on a real Linux VM" is **closed for aarch64**.
The remaining credibility gap is **x86_64** — both tested environments are Apple Silicon aarch64.

---

## What is now proven

1. 5/5 scenario suite passes on two kernels: 6.10.14-linuxkit and 5.15.0-181-generic
2. All verdict types and JSON fields are consistent across both kernels
3. bpf_get_netns_cookie UNSUPPORTED on kprobe/sched_cls on both kernels (with evidence)
4. skb->network_header at ip_do_fragment unreliable on both kernels (more severe on 5.15)
5. Two-signal corroboration strategy is valid on both kernels
6. ip route flush cache effective on both kernels
7. CO-RE BTF resolution works on 5.15.0-181-generic (5.8MB vmlinux)
8. bpftool is kernel-matched on Ubuntu 22.04 (contrasted with linuxkit)
9. Makefile `make bpf` now correctly compiles all four BPF objects
10. Preflight script passes 20/20 on Ubuntu 22.04 5.15.0-181-generic

---

## What remains unproven

- x86_64: PT_REGS_PARM1 for `__TARGET_ARCH_x86` path — compiled from macOS but not
  run on a real x86_64 kernel. This is the top Day 10 priority.
- Other kernels: 5.10.x, 6.1.x, 6.8.x — not tested
- VXLAN-specific scoping of ip_do_fragment — still global on both tested kernels
- Production Kubernetes environments (Flannel, Calico, Cilium with real pods)
- bpftrace on a kernel with working bpftrace (0.16+ with matching headers)

---

## Day 10 focus

Top priority: x86_64 validation. Both current kernel matrix entries are aarch64.
The `__TARGET_ARCH_x86` code path is written and compiled but never run.

Options:
1. GitHub Actions `ubuntu-22.04` runner is free for public repos and provides x86_64 5.15.x
2. Lima VM with `--vm-type qemu` and `--arch x86_64` (requires qemu, very slow on Apple Silicon)
3. Cloud VM (AWS t3.small or GCP e2-small)

Recommended: GitHub Actions CI job that runs `make preflight && make bpf && make build &&
go test ./... && BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`.
This would add x86_64 5.15.x to the matrix at zero additional infrastructure cost.
