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
| `make scenarios` | Run `scripts/run-scenarios.sh` with Docker (all 5 scenarios) |
| `make cleanup-bpf` | Run `scripts/cleanup-bpf.sh` to remove TC filters and maps |

## Known kernel-dependent behavior

### Route MTU cache effect

After large-packet runs in the same namespace, the Linux kernel caches a reduced
PMTU. Observed on 6.10.14-linuxkit:

```
ip netns exec ns1 ip route show cache
  10.244.0.2 dev vxlan0
      cache expires 597sec mtu 1350
```

The kernel learned `mtu 1350` (correct: 1400 underlay - 50 VXLAN overhead).
On subsequent runs without a cache flush, the kernel uses 1350B for inner
packets → outer IP = 1400B (at the underlay MTU boundary, not over it) →
`max_outer_ip_len` may be < underlay_mtu → conservative `global_unscoped`
verdict instead of `global_corroborated`.

**Proven workaround (6.10.14-linuxkit):** `ip route flush cache` clears the
PMTU entry (exit 0, cache empty after flush). After flush, large pings
retrigger full-size outer packets (1438B), restoring the corroborated verdict.

```sh
# Between runs in the same namespaces:
bash scripts/cleanup-bpf.sh
ip netns exec ns1 ip route flush cache
ip netns exec ns2 ip route flush cache
```

**Full reset (any kernel):** tear down and recreate namespaces:
```sh
bash scripts/teardown-netns.sh
bash scripts/setup-netns.sh
```

`scripts/run-scenarios.sh` recreates namespaces for scenarios 1-4 and uses
`ip route flush cache` for scenario 5 (second-run idempotency test).

The `ip route flush cache` behavior is documented in `evidence/day-08-route-cache.md`.

### skb->len value at ip_do_fragment entry

The `frag_max_skb_len` field in JSON may report either the outer IP length
(1438 B in clean runs) or the inner IP length (1388 B after route cache
populates). Both readings come from `skb->len` at ip_do_fragment entry; which
one is returned depends on kernel internals. This is documented and not hidden.

## x86_64 BPF compilation notes

When compiling BPF programs on an x86_64 host, `clang -target bpf` does not
define `__x86_64__`. This causes glibc's `gnu/stubs.h` (pulled in via
`/usr/include/x86_64-linux-gnu/sys/socket.h`) to try to include `gnu/stubs-32.h`,
which requires `gcc-multilib` (or `libc6-dev-i386`) to be installed.

The Makefile adds `-D__x86_64__` to the x86_64 arch include flags, which prevents
`stubs-32.h` from being requested. As belt-and-suspenders, `gcc-multilib` can be
installed to satisfy the include on systems that do not apply the `-D` workaround.

```sh
# If you hit "fatal error: 'gnu/stubs-32.h' file not found":
sudo apt-get install gcc-multilib
# or just use make bpf, which passes -D__x86_64__ for x86_64
```

This was discovered on GitHub Actions ubuntu-22.04 (kernel 6.8.0-1052-azure,
x86_64) on Day 10 of development. The fix is in Makefile:14–20.

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
