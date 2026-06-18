# Day 9 — VM build and test environment

**Date:** 2026-06-17
**VM:** Lima vxlan-test (macOS VZ hypervisor, Apple Silicon host)
**Environment type:** Real Linux VM (not Docker Desktop)

## System information

```
uname -a:
  Linux lima-vxlan-test 5.15.0-181-generic #191-Ubuntu SMP Fri May 22 19:27:05 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux

Distro:
  Ubuntu 22.04.5 LTS (Jammy Jellyfish)

go version:
  go version go1.21.13 linux/arm64

clang --version:
  Ubuntu clang version 14.0.0-1ubuntu1.1

bpftool version:
  /usr/lib/linux-tools/5.15.0-181-generic/bpftool v5.15.199
  (kernel-matched — same version as running kernel, unlike linuxkit where bpftool was mismatched)
```

## Unit tests

```
go test ./...

?   github.com/mansoormmamnoon/vxlan-tracer/cmd/vxlan-tracer    [no test files]
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap     0.002s
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag       0.002s
?   github.com/mansoormmamnoon/vxlan-tracer/internal/loader     [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/internal/output     [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_frag_scope  [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_helper      [no test files]
```

Result: 14 unit tests PASS (same as macOS and Docker runs).

## BPF compilation — make bpf

All four BPF objects compiled on 5.15.0-181-generic with clang 14:

```
make bpf

  prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=aarch64
  CC  bpf/tc_ingress_eth0.bpf.o
  CC  bpf/tc_egress_vxlan0.bpf.o
  CC  bpf/kprobes.bpf.o
  CC  bpf/frag_kprobes.bpf.o
BPF build complete.
-rw-r--r-- 1 root root  7.5K bpf/frag_kprobes.bpf.o
-rw-r--r-- 1 root root  7.6K bpf/kprobes.bpf.o
-rw-r--r-- 1 root root  17K  bpf/tc_egress_vxlan0.bpf.o
-rw-r--r-- 1 root root  18K  bpf/tc_ingress_eth0.bpf.o
```

0 compiler warnings. All BPF objects accepted by clang for the bpf target.
BPF verifier acceptance tested in the scenario run (evidence/day-09-vm-scenarios.md).

## Go build — make build

```
make build

go generate ./...
go build -o dist/vxlan-tracer ./cmd/vxlan-tracer/
  built: dist/vxlan-tracer
```

Binary: `dist/vxlan-tracer` — ELF 64-bit LSB, ARM aarch64, 4.8M
Native build (not cross-compiled). Runs directly on the VM.

## Bug found and fixed: frag_kprobes.bpf.o missing from make bpf

The `make bpf` target was missing `bpf/frag_kprobes.bpf.o`. The Docker `scenarios`
Makefile target compiled it inline, so the gap was not visible in prior testing.
The `make bpf` target now correctly includes all four objects.

This also fixes the `scripts/run-scenarios.sh` preflight check, which requires all
four `.bpf.o` files to be present in `BPF_DIR` before running any scenario.

## Preflight check

See `evidence/day-09-vm-preflight.md` — 20/20 PASS on this kernel.

## What is confirmed on 5.15.0-181-generic

- Unit tests pass (Go-only, no kernel dep)
- All four BPF objects compile with clang 14 targeting the `bpf` target
- Native binary builds correctly
- Preflight: all 20 checks pass

## What is not yet confirmed on 5.15.0-181-generic

- BPF verifier acceptance (tested in scenario run)
- CO-RE skb field resolution via BTF
- kprobe attachment for ip_do_fragment and icmp_rcv
- TC filter attachment
- Scenario suite verdicts
