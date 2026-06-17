# Day 6: ip_do_fragment kprobe — build verification (commit 2)

## What was built

`bpf/frag_kprobes.bpf.c` — count-only `ip_do_fragment` kprobe. No skb
field reads (no CO-RE structs) in this commit. Just attaches to
`kprobe/ip_do_fragment` and increments `frag_events_total.total` (a single
struct frag_val entry in an ARRAY map, key 0).

## Compile command

```sh
clang -O2 -g -target bpf \
  -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/frag_kprobes.bpf.c -o /tmp/bpfobjs/frag_kprobes.bpf.o
```

Run inside Docker ubuntu:22.04 with `apt`-installed `clang`/`libbpf-dev`.
No `-D__TARGET_ARCH_arm64` needed — this kprobe accesses no arch-specific
struct members in commit 2 (no CO-RE, no pt_regs accesses beyond a
trivial counter increment).

## Compiler output

Exit code: **0** — no warnings, no errors.

## ELF section dump (`llvm-objdump -h`)

```
Sections:
Idx Name                        Size
  3 kprobe/ip_do_fragment       00000060   TEXT
  5 .maps                       00000020   DATA
  6 license                     00000004   DATA
 16 .BTF                        000003c6
```

The `kprobe/ip_do_fragment` section exists and is 96 bytes (0x60) —
correct for a minimal kprobe body (map lookup + atomic add + return 0).

## Symbol table verification (`llvm-objdump -t | grep frag`)

```
0000000000000000 g  F kprobe/ip_do_fragment  00000060 kprobe_ip_do_fragment
0000000000000000 g  O .maps                  00000020 frag_events_total
```

Both symbols present — `kprobe_ip_do_fragment` (the program, matching the
name the Go loader will use) and `frag_events_total` (the ARRAY map, 0x20
bytes for the BPF map-definition struct).

## Object file sizes (all four objects)

```
frag_kprobes.bpf.o    6,064 bytes  ← new
kprobes.bpf.o         7,672 bytes
tc_egress_vxlan0.bpf.o  16,952 bytes
tc_ingress_eth0.bpf.o   17,912 bytes
```

`frag_kprobes.bpf.o` is smaller than `kprobes.bpf.o` because it has no
CO-RE relocations (no partial sk_buff struct, no `preserve_access_index`
access in this commit).

## What is proven

- `frag_kprobes.bpf.c` compiles cleanly with the same toolchain
  (`apt`-installed clang on ubuntu:22.04) used for all other BPF objects.
- The ELF output has the expected section (`kprobe/ip_do_fragment`), map
  (`frag_events_total`), and program name (`kprobe_ip_do_fragment`) that
  the Go loader will look up.
- No CO-RE annotations are present in this commit, which eliminates the
  class of BTF-relocation failures seen in Day 5 commit 1 (libbpf-vs-kernel
  BTF mismatch). The count-only program is loader-agnostic in that sense.

## What remains unproven

- The kprobe has not been loaded into a real kernel yet. Load and attach
  happen in commit 3 (Go loader) and are verified by the live Docker test
  in that commit.
- `ip_do_fragment` is a T symbol on this kernel (confirmed via ftrace in
  Day 2 Finding 1), but the kprobe attachment will be the first test via
  cilium/ebpf's `link.Kprobe("ip_do_fragment", ...)` API.
- The count-only version does not read skb->len, so it does not confirm
  which packet sizes trigger fragmentation — that enrichment is commit 7.
