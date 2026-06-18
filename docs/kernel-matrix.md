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

| Kernel | Architecture | Status | Notes |
|--------|-------------|--------|-------|
| 6.10.14-linuxkit | aarch64 | ✅ TESTED | Docker Desktop on Apple Silicon. All 5 scenarios pass. |

## Target matrix for Day 9+

| Kernel | Architecture | Target | How to obtain |
|--------|-------------|--------|--------------|
| 5.15.x LTS | x86_64 | High priority | GitHub Actions Ubuntu 22.04 runner, or AWS t3.small |
| 5.15.x LTS | aarch64 | Medium | AWS t4g.small or Lima VM with Ubuntu 22.04 arm64 |
| 6.8.x LTS | x86_64 | Medium | GitHub Actions Ubuntu 24.04 runner |
| 6.1.x LTS | x86_64 | Optional | Debian 12 VM |

### Why 5.15 LTS is important

5.15 is the production kernel for Ubuntu 22.04 LTS, which is the most common
Kubernetes node OS (EKS, GKE, self-managed). Most production VXLAN blackhole
incidents occur on 5.15. The tool has not been tested there.

Known risk areas:
- `ip_do_fragment` kprobability: should work (T symbol in 5.15), but not verified.
- `icmp_rcv` kprobe with CO-RE filtering: should work, but BTF field offsets may differ.
- TC clsact qdisc behavior: stable across kernel versions, low risk.
- `bpf_get_netns_cookie` availability: NOT available in kprobe on 5.15 either
  (the restriction predates 6.x — it's a design decision, not a version regression).

## Commands to run the scenario suite on a target VM

Assuming the VM runs Ubuntu 22.04 and you have SSH access:

```bash
# 1. Copy the pre-compiled binary (built with make build-linux-amd64 on your host)
scp dist/vxlan-tracer-linux-amd64 user@vm:/tmp/vxlan-tracer-linux-amd64

# 2. SSH into the VM and compile BPF objects there
ssh user@vm
sudo apt-get install -y clang llvm libbpf-dev linux-libc-dev iproute2 iputils-ping \
    iptables python3 python3-scapy
git clone <repo> /tmp/vxlan-tracer && cd /tmp/vxlan-tracer
mkdir -p /tmp/bpfobjs
clang -O2 -g -target bpf -I/usr/include -I/usr/include/x86_64-linux-gnu \
    -D__TARGET_ARCH_x86 -c bpf/kprobes.bpf.c -o /tmp/bpfobjs/kprobes.bpf.o
# ... compile all four BPF objects ...

# 3. Run scenario suite
sudo bash scripts/setup-bpf-fs.sh
sudo BINARY=/tmp/vxlan-tracer-linux-amd64 BPF_DIR=/tmp/bpfobjs DURATION=15s \
    bash scripts/run-scenarios.sh 2>&1 | tee /tmp/vm-scenarios-$(uname -r).log

# 4. Capture kernel information for evidence
uname -a >> /tmp/vm-scenarios-$(uname -r).log
```

## What constitutes a kernel matrix test result

A kernel matrix entry is only valid if:
1. `uname -a` output is recorded.
2. All 5 scenarios in `scripts/run-scenarios.sh` are run.
3. The result (pass/fail per scenario) is recorded in `evidence/test-results.md`.
4. Any verifier errors or unexpected behavior are documented.

A container image label is NOT sufficient. `uname -a` from inside the test
environment is the authoritative record of the kernel under test.

## Current claim

vxlan-tracer has been tested on:
```
Linux 6.10.14-linuxkit #1 SMP Thu Aug 14 19:26:13 UTC 2025 aarch64
```

No other kernel has been tested. Claims of compatibility with other kernels
are untested and must not be made.
