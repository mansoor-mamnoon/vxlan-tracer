# Kernel version matrix and testing plan

## Critical fact: Docker containers do not change the kernel

Docker containers share the host kernel. An `ubuntu:22.04` container on Docker
Desktop for Mac runs on the Docker Desktop LinuxKit kernel (currently 6.10.14),
NOT on Ubuntu 22.04's kernel (5.15 LTS). A container image label only describes
the userspace; the kernel is always the host's.

```
uname -r inside any Docker Desktop container:
  6.10.14-linuxkit      ← Docker Desktop's LinuxKit kernel
  NOT 5.15.x-generic    ← Ubuntu 22.04's actual kernel
```

**Consequence:** Running vxlan-tracer tests inside different Docker image tags
does NOT constitute kernel-version testing. Any claim that "tested on kernel X"
based on a container image label is incorrect if `uname -r` shows a different
kernel.

## What kernel testing actually requires

| Method | Kernel | Notes |
|--------|--------|-------|
| Docker Desktop (Mac/Win) | 6.10.14-linuxkit | Only kernel tested so far |
| Lima VM (Mac) | Any Linux kernel; set in lima config | Free, local, recommended for CI |
| UTM VM (Mac) | Any kernel from ISO | Good for arm64 testing |
| Cloud instance (GCP/AWS/Azure) | Provider-managed kernel | Use for x86_64 or specific LTS |
| Bare-metal Linux | Distro kernel | Most reliable; highest effort |
| GitHub Actions (Linux runner) | Ubuntu 22.04 kernel (5.15.x) | Free for public repos |

## Current tested matrix

### Entry 1

- **Kernel:** 6.10.14-linuxkit
- **Distro:** Docker Desktop LinuxKit (not a standard distro)
- **Arch:** aarch64
- **Environment:** `--privileged` Docker container on Docker Desktop for Mac (Apple Silicon)
- **Date:** 2026-06-16 (Day 7)
- **Scenarios:** 5/5 pass
- **Result:** ✅ PASS
- **Notes:** Docker's kernel, not Ubuntu. bpftool version mismatches running kernel (v5.15.199 on 6.10.14 kernel). bpf_get_netns_cookie unavailable for kprobe/sched_cls. skb->network_header inconsistently points to inner IP under route cache.
- **Evidence:** evidence/day-07-scenarios.md, evidence/day-08-helper-availability.md, evidence/day-08-frag-scope-spike.md

### Entry 2

- **Kernel:** 5.15.0-181-generic
- **Distro:** Ubuntu 22.04.5 LTS (Jammy Jellyfish)
- **Arch:** aarch64
- **Environment:** Lima VM (macOS VZ hypervisor on Apple Silicon host), not Docker
- **Date:** 2026-06-17 (Day 9)
- **Scenarios:** 5/5 pass
- **Result:** ✅ PASS
- **Notes:**
  - ip_do_fragment: T symbol, kprobeable — same as linuxkit
  - icmp_rcv: T symbol, kprobeable — same as linuxkit
  - BTF: /sys/kernel/btf/vmlinux present (5.8 MB); CO-RE resolves correctly
  - bpftool: kernel-matched (v5.15.199 matches 5.15 kernel), better than linuxkit
  - bpf_get_netns_cookie: UNSUPPORTED for kprobe/sched_cls (verifier: "unknown func bpf_get_netns_cookie#122")
  - Header parsing: skb->network_header points to inner IP even on first run (more severe than linuxkit)
  - ip route flush cache: effective — same as linuxkit
  - All verdict JSON fields identical to linuxkit results
- **Evidence:** evidence/day-09-vm-preflight.md, evidence/day-09-vm-env.md, evidence/day-09-vm-scenarios.md, evidence/day-09-vm-helper-scope.md

### Entry 3

- **Kernel:** 6.8.0-1052-azure
- **Distro:** Ubuntu 22.04.5 LTS
- **Arch:** x86_64
- **Environment:** GitHub Actions ubuntu-22.04 (Azure-hosted runner)
- **Date:** 2026-06-18 (Day 10)
- **Scenarios:** 5/5 pass
- **Result:** ✅ PASS
- **Notes:**
  - BTF: /sys/kernel/btf/vmlinux present (6020051 bytes)
  - bpffs: pre-mounted on GitHub-hosted runners
  - Capabilities: sudo/root has CapEff=0x000001ffffffffff; ip link add dummy blocked at global netns (runner restriction), but TC ops inside netns succeed
  - ip_do_fragment: T symbol, kprobeable; kprobe attaches and fires correctly
  - icmp_rcv: T symbol, kprobeable; filters correctly to ICMP type=3/code=4
  - BPF compile: required `-D__x86_64__` (stubs-32.h fix) — first run failed without it
  - PT_REGS_PARM1 (x86 rdi): confirmed correct — frag_max_skb_len=1438 matches aarch64
  - All five verdict JSON fields identical to aarch64 results
  - ip route flush cache effective (scenario 5 idempotency passes)
  - perf_event_paranoid=4 (WARN in preflight) did not prevent kprobe attachment as root
- **Evidence:** evidence/day-10-x86-vm-scenarios.md, evidence/day-10-github-actions-run1.md, evidence/day-10-arch-comparison.md

## Target matrix for remaining work

| Kernel | Architecture | Status | How to obtain |
|--------|-------------|--------|--------------|
| 6.8.0-1052-azure | x86_64 | in progress | GitHub Actions ubuntu-22.04 runner |
| 6.8.x LTS | x86_64 | future | GitHub Actions ubuntu-24.04 runner |
| 6.8.x LTS | aarch64 | future | Lima VM with Ubuntu 24.04 arm64 |
| 6.1.x LTS | x86_64 | future | Debian 12 VM |

Note: ubuntu-22.04 runners provide kernel 6.8.0-1052-azure (Azure infrastructure
kernel), not 5.15.x-generic as earlier assumed. This is still x86_64 with BTF.

### Why x86_64 still matters

Both previously confirmed kernels are aarch64. The kprobe PT_REGS_PARM1 register
convention differs between aarch64 and x86_64 — the `-D__TARGET_ARCH_*` flag
selects the correct convention, but the x86_64 path (`di` register) has only
been compiled and not run-tested. Entry 3 is the first x86_64 run.

## Commands to run the scenario suite

```bash
# On any Linux x86_64 Ubuntu 22.04 host:
git clone https://github.com/mansoor-mamnoon/vxlan-tracer.git && cd vxlan-tracer
sudo apt-get install -y clang llvm libbpf-dev linux-tools-generic \
    iproute2 iputils-ping iptables python3 python3-pip make gcc build-essential gcc-multilib
sudo pip3 install scapy
# Install Go 1.21+ — see https://go.dev/dl/
sudo make preflight       # verify 20+ checks pass
sudo make bpf             # compile all 4 BPF objects
make build                # build Go binary
make test                 # 14 unit tests
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh
```

See `docs/x86-cloud-validation.md` for cloud VM step-by-step instructions.

## What constitutes a kernel matrix test result

A kernel matrix entry is only valid if:
1. `uname -a` output is recorded.
2. All 5 scenarios in `scripts/run-scenarios.sh` are run.
3. The result (pass/fail per scenario) is recorded in `evidence/test-results.md`.
4. Any verifier errors or unexpected behavior are documented.

A container image label is NOT sufficient. `uname -a` from inside the test
environment is the authoritative record of the kernel under test.
