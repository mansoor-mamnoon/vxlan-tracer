# bpf/

BPF C programs for vxlan-tracer. Not yet implemented — stubs only.

## Programs (planned)

| File | Hook | Direction | Status |
|------|------|-----------|--------|
| `tc_egress_vxlan0.bpf.c` | clsact on vxlan0 | egress | not started |
| `tc_ingress_eth0.bpf.c` | clsact on eth0 | ingress | not started |
| `kprobes.bpf.c` | ip_do_fragment, icmp_send, icmp_rcv | — | not started |

## Build (Linux only)

```sh
make bpf
```

Requires: clang 12+, libbpf-dev, linux-headers matching target kernel.

## Verifier constraints (to be addressed in implementation)

- `iph->ihl` is variable (4-60 bytes). Must clamp to `[5, 15]` before using
  as a pointer offset or the verifier will reject the program.
- 512-byte BPF stack limit. Do not store intermediate parsed structs on the
  stack — use only the final 5-tuple key struct and direct field reads.
- `bpf_probe_read_kernel` required for reading from `struct sk_buff` fields in
  kprobe/fentry context.
- `__sync_fetch_and_add` or `BPF_ATOMIC` ops (kernel 5.12+) for counter
  increments in map values.
- fentry requires BTF (`/sys/kernel/btf/vmlinux` must exist).

## Map definitions

Shared across all programs via `vmlinux.h` and `maps.h` (to be created).
See docs/architecture.md for the full map schema.
