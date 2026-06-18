# VM validation guide

This document describes how to run vxlan-tracer on a real Linux VM or bare-metal
host. Docker Desktop (linuxkit kernel) has been the only test environment through
Day 8. A real VM is required to add kernel diversity to the test matrix.

## Why Docker Desktop is not enough

Docker containers share the host kernel. On Docker Desktop for Mac, all
containers run on `6.10.14-linuxkit`. To test a different kernel (e.g., Ubuntu
22.04's `5.15.x`, Ubuntu 24.04's `6.8.x`), you need a real VM or bare-metal host.

## Recommended VM options

| Method | Kernel | Notes |
|--------|--------|-------|
| Lima VM (Mac) | Any Linux kernel; set in `.yaml` config | Free, local, recommended |
| UTM VM (Mac) | Any kernel from ISO | Good for arm64 testing |
| GitHub Actions `ubuntu-22.04` runner | 5.15.x x86_64 | Free for public repos |
| AWS t3.small / t4g.small | Provider kernel | Cloud, billable |
| GCP e2-small | Provider kernel | Cloud, billable |
| Bare-metal Linux | Distro kernel | Most reliable |

## Minimum requirements

| Requirement | Value |
|-------------|-------|
| OS | Linux (any distro) |
| Root access | Required (CAP_BPF + CAP_NET_ADMIN) |
| Kernel | 5.15+ (BTF/CO-RE required) |
| BTF | `/sys/kernel/btf/vmlinux` must exist |
| bpffs | `/sys/fs/bpf` must be mounted |
| clang/llvm | 12+ |
| Go | 1.21+ |
| python3-scapy | any |
| iproute2 | any (for ip netns, ip link, ip route) |
| iptables | any |

## Step-by-step: Ubuntu 22.04 / 24.04 VM

### 1. Install dependencies

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    clang llvm libbpf-dev \
    linux-tools-generic linux-tools-$(uname -r) \
    iproute2 iputils-ping iptables \
    python3 python3-pip \
    make gcc git build-essential
sudo pip3 install scapy
```

### 2. Install Go

```bash
# Check if Go is already installed
go version 2>/dev/null && echo "Go already installed" && exit 0

# Download and install Go 1.21 (adjust for aarch64 or amd64)
GOARCH=$(dpkg --print-architecture | sed 's/amd64/amd64/;s/arm64/arm64/')
curl -sL "https://go.dev/dl/go1.21.13.linux-${GOARCH}.tar.gz" \
    | sudo tar -xz -C /usr/local
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.profile
source ~/.profile
go version
```

### 3. Mount bpffs if not already mounted

```bash
mount | grep -q '/sys/fs/bpf' && echo "bpffs already mounted" \
    || sudo mount -t bpf bpf /sys/fs/bpf
ls /sys/fs/bpf/  # should show directory (empty is ok)
```

### 4. Verify BTF availability

```bash
ls -lh /sys/kernel/btf/vmlinux
# Expected: -r--r--r-- 1 root root <size> vmlinux
# If missing: BTF is not enabled in this kernel config — CO-RE BPF programs
# will not load. Try a different kernel or distro.
```

### 5. Clone or copy the repository

```bash
# Option A: clone from remote (if repo is public)
git clone <repo-url> /opt/vxlan-tracer
cd /opt/vxlan-tracer

# Option B: copy from macOS host (Lima VM example)
# limactl copy <local-repo-path> vxlan-test:/opt/vxlan-tracer
```

### 6. Compile BPF objects

```bash
cd /opt/vxlan-tracer
sudo make bpf
# Expected output: BPF build complete. bpf/*.bpf.o
```

### 7. Build Go binary

```bash
make build
# Expected: dist/vxlan-tracer (native binary)
```

### 8. Run preflight check

```bash
sudo make preflight
# All checks should pass before running scenarios
```

### 9. Run scenario suite

```bash
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s \
    bash scripts/run-scenarios.sh
# Expected: Results: 5 passed, 0 failed
```

## Cloud VM security group notes

The scenario suite uses local network namespaces only. It does not require:
- Inbound traffic from the internet
- Any open firewall ports
- VPC routing changes

All traffic is between `ns1` and `ns2`, two local namespaces connected via
`veth` pairs. No external connectivity is needed.

You do need:
- SSH access to the VM (port 22, outbound from your workstation)
- Root access on the VM

## Valid evidence checklist

A kernel matrix entry is only valid if all of the following are recorded:

```
[ ] uname -a output
[ ] go version output
[ ] clang --version output
[ ] bpftool version or note if unavailable
[ ] make test result (go test ./...)
[ ] make bpf result (BPF object compilation)
[ ] make preflight result
[ ] scripts/run-scenarios.sh result (pass/fail per scenario)
[ ] JSON output for each passing scenario (or error for each failing scenario)
[ ] Any kernel-specific differences from 6.10.14-linuxkit behavior
```

A Docker image label is NOT sufficient. `uname -a` from inside the test
environment is the authoritative record of the kernel under test.

## Lima VM quick start (macOS)

```bash
# Install Lima
brew install lima

# Start Ubuntu 22.04 VM (aarch64, uses macOS VZ hypervisor)
limactl start --name vxlan-test template://ubuntu-22.04

# Open a root shell in the VM
limactl shell --workdir /tmp vxlan-test sudo -i

# Inside the VM, follow steps 1–9 above
# The macOS home directory is mounted read-only at ~/
# Copy the repo into the VM's writable space:
cp -r ~/Desktop/Projects\ \&\ Research/GitHub\ Projects/vxlan-tracer /tmp/vxlan-tracer
cd /tmp/vxlan-tracer
```

## Expected differences from LinuxKit 6.10.14

| Behavior | 6.10.14-linuxkit | Ubuntu 22.04 5.15.x | Status |
|----------|-----------------|---------------------|--------|
| ip_do_fragment kprobeable | YES (T symbol) | Expected YES | Unverified |
| BTF at /sys/kernel/btf/vmlinux | YES | Expected YES (Ubuntu 22.04 ships BTF) | Unverified |
| bpf_get_netns_cookie in kprobe | NO (verifier error) | Expected NO (design decision) | Unverified |
| ip route flush cache effective | YES | Expected YES | Unverified |
| linux-tools-$(uname -r) | N/A (linuxkit) | Required for bpftool | Unverified |

"Unverified" means it has not been tested on that kernel. Update this table after
each real VM test run.
