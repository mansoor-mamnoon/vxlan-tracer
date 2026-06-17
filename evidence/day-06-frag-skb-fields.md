# Day 6: ip_do_fragment kprobe CO-RE skb->len enrichment (commit 7)

## What changed in frag_kprobes.bpf.c

Added:
- `#include <bpf/bpf_core_read.h>`
- Partial `struct sk_buff { unsigned int len; } __attribute__((preserve_access_index))` for CO-RE
- `PT_REGS_PARM3(ctx)` to get the skb pointer (arg3 of ip_do_fragment: net, sk, *skb*, output)
- `BPF_CORE_READ(skb, len)` to read the pre-fragmentation outer packet length
- Update of `frag_val.max_skb_len` if new len > current max
- Update of `frag_val.last_seen_ns` with `bpf_ktime_get_ns()`
- Updated compile command: now requires `-D__TARGET_ARCH_arm64` (for PT_REGS_PARM3 on arm64)

## Compile result (Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64)

```sh
clang -O2 -g -target bpf \
  -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -D__TARGET_ARCH_arm64 \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/frag_kprobes.bpf.c -o /tmp/bpfobjs/frag_kprobes.bpf.o
```

Exit code: **0** — no warnings or errors.

## ELF section comparison

| Version | Program size |
|---------|-------------|
| commit 2 (count-only, no CO-RE) | 0x60 = 96 bytes |
| commit 7 (CO-RE, skb->len) | 0xd8 = 216 bytes |

The 2.25× size increase reflects the added argument read, BPF_CORE_READ
relocation stub, and two conditional branches (max_skb_len update, last_seen_ns
assignment).

## BTF section

```
.BTF      0x491 bytes  (vs 0x3c6 for count-only)
.BTF.ext  0x14c bytes  (CO-RE relocations for sk_buff.len access)
.rel.BTF  0x020 bytes
.rel.BTF.ext  0x110 bytes
```

CO-RE relocations are present — `sk_buff.len` will be resolved from
`/sys/kernel/btf/vmlinux` at load time by cilium/ebpf, not baked into the
BPF bytecode at compile time.

## What is proven

- The CO-RE version compiles cleanly with `-D__TARGET_ARCH_arm64` on the
  same apt-installed clang used for all other BPF objects.
- The BTF.ext section contains the CO-RE relocation record for `sk_buff.len`.
  At load time, cilium/ebpf will resolve the actual byte offset of `len`
  within the kernel's sk_buff struct from `/sys/kernel/btf/vmlinux`.
- The ELF symbol table confirms `kprobe_ip_do_fragment` and `frag_events_total`
  are both present with the expected sizes.

## What remains unproven

- Whether the CO-RE relocation for `sk_buff.len` resolves correctly at load
  time on this kernel's BTF (kernel 6.10.14-linuxkit). This is verified
  indirectly in commits 8 / the VXLAN_FRAGMENTATION_OBSERVED test: if
  cilium/ebpf rejects the program at load time (CO-RE relocation failure),
  the binary will error out before printing a verdict. A clean exit with
  a correct verdict in commit 8 proves the CO-RE load succeeded.
- Whether `max_skb_len` is non-zero after large traffic (the value is stored
  in the BPF map but the current verdict output does not print it; it would
  appear in JSON output in commit 9 or a future bpftool dump).
- The exact skb->len value at ip_do_fragment entry for a 1438-byte outer IP
  packet. On aarch64/linuxkit, skb->len includes all fragment data; the exact
  value depends on kernel-internal headroom and may include L2 header bytes.

## Why non-atomic max_skb_len update is acceptable

The non-atomic compare-and-update (`if (skb_len > v->max_skb_len) v->max_skb_len = skb_len`)
can race between concurrent ip_do_fragment calls (e.g., if both ns1 and ns2 are
fragmenting simultaneously). The worst outcome is that max_skb_len reflects a
slightly stale maximum from a past call. For a diagnostic tool this is harmless:
we only need to know "was there oversized outer packet traffic?" not the precise
maximum to the byte.
