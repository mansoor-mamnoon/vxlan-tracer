# Reproducing vxlan-tracer results

This document explains what is required to reproduce the test results in
`evidence/` and what cannot be reproduced outside that environment.

## Environment requirements

| Requirement | Minimum | Tested |
|-------------|---------|--------|
| OS | Linux (any distro) | ubuntu:22.04 Docker image |
| Kernel | 5.15+ (BTF/CO-RE required) | 6.10.14-linuxkit (aarch64) |
| Architecture | x86_64 or aarch64 | aarch64 only |
| Privileges | `CAP_BPF` + `CAP_NET_ADMIN` + `CAP_NET_RAW` | `--privileged` Docker |
| bpffs | Mounted at `/sys/fs/bpf` | `scripts/setup-bpf-fs.sh` |
| clang/llvm | 12+ | 14 (ubuntu:22.04 package) |
| python3-scapy | any | 2.5.0 |

## Why macOS cannot run kernel tests

The BPF programs require Linux kernel infrastructure:
- `CAP_BPF`, `CAP_NET_ADMIN` — not present on macOS
- `bpffs` (`/sys/fs/bpf`) — Linux-only filesystem
- `kprobes` (icmp_rcv, ip_do_fragment) — Linux kernel tracepoints
- `tc clsact` qdisc — Linux traffic control, not available on macOS networking
- Network namespaces (`ip netns`) — Linux-only

The Go binary and BPF C programs cross-compile on macOS for Linux targets
(`GOOS=linux GOARCH=arm64`), but they can only execute on Linux.

## Docker quickstart (arm64 host)

```sh
# 1. Cross-compile the binary (on macOS/Linux host)
GOOS=linux GOARCH=arm64 go build -o /tmp/vxlan-tracer-linux-arm64 ./cmd/vxlan-tracer

# 2. Compile BPF objects inside Docker (requires clang for target arch)
docker run --rm \
  -v "$(pwd)":/work \
  ubuntu:22.04 bash -c "
    apt-get update -qq && apt-get install -y -qq clang llvm libbpf-dev linux-libc-dev iproute2
    cd /work
    clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
      -D__TARGET_ARCH_arm64 -c bpf/kprobes.bpf.c -o /tmp/kprobes.bpf.o
    # ... (see scripts/compile-bpf.sh for full set)
  "

# 3. Run all four diagnostic scenarios
docker run --rm --privileged \
  -v "$(pwd)":/work \
  -v /tmp/vxlan-tracer-linux-arm64:/tmp/vxlan-tracer-linux-arm64 \
  ubuntu:22.04 bash -c "
    apt-get update -qq && apt-get install -y -qq iproute2 iputils-ping iptables python3 python3-scapy clang llvm libbpf-dev linux-libc-dev
    cd /work && bash scripts/setup-bpf-fs.sh
    BINARY=/tmp/vxlan-tracer-linux-arm64 BPF_DIR=/tmp/bpfobjs DURATION=15s \
      bash scripts/run-scenarios.sh
  "
```

Or use the Makefile target:

```sh
make scenarios
```

## Makefile targets

| Target | What it does |
|--------|-------------|
| `make lab-up` | Create ns1/ns2 VXLAN lab in network namespaces |
| `make lab-down` | Remove namespaces and cleanup |
| `make smoke-small` | Send a 40-byte inner ping (safe; should not fragment) |
| `make smoke-large` | Send a 1360-byte inner ping (oversized; triggers fragmentation) |
| `make scenarios` | Run `scripts/run-scenarios.sh` with Docker (all 4 scenarios) |
| `make cleanup-bpf` | Run `scripts/cleanup-bpf.sh` to remove TC filters and maps |

## Known kernel-dependent behavior

### Route MTU cache effect

After repeated large-packet runs in the same lab, the Linux kernel may cache
a reduced PMTU for the 192.168.100.x/24 route. On the next run, the kernel
may send smaller outer packets (e.g., 1398 B instead of 1438 B). If
`max_outer_ip_len` drops below the underlay MTU (1400), the two-signal
fragmentation verdict path falls back to the conservative message:
"ip_do_fragment is a global kernel function..."

To avoid this: run `scripts/cleanup-bpf.sh` AND delete the route MTU cache:
```sh
ip netns exec ns1 ip route flush cache
```

Or use `scripts/run-scenarios.sh`, which always runs a fresh cleanup between
scenarios, which recreates the network namespaces and resets the route cache.

### skb->len value at ip_do_fragment entry

The `frag_max_skb_len` field in JSON may report either the outer IP length
(1438 B in clean runs) or the inner IP length (1388 B after route cache
populates). Both readings come from `skb->len` at ip_do_fragment entry; which
one is returned depends on kernel internals. This is documented and not hidden.

## Capabilities required

| Capability | Why |
|-----------|-----|
| `CAP_BPF` | Load and attach BPF programs; create and pin maps |
| `CAP_NET_ADMIN` | Manage TC qdiscs and filters; create network namespaces |
| `CAP_NET_RAW` | Attach kprobes; raw socket access for Scapy PTB injection |

In practice, root (`--privileged` in Docker or `sudo` on bare metal) satisfies
all three.

## What cannot be reproduced without a Linux kernel

- All four diagnostic verdicts: the BPF programs do not execute without a kernel.
- The PTB suppression detection: requires real netfilter/iptables hook path.
- The fragmentation kprobe: requires `ip_do_fragment` in the kernel BTF.
- Map pinning: requires a mounted bpffs.

Unit tests (`go test ./...`) run on any platform and cover the Go-side verdict
logic, but they do not exercise the BPF programs or the kernel hooks.
