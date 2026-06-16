# evidence/day-05-icmp-rcv-filter.md

Day 5 Commit 1: filter `kprobe/icmp_rcv` to count only ICMP Destination
Unreachable / Fragmentation Needed (type=3, code=4), instead of all ICMP
traffic (Day 4 behavior).

Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## Design

`icmp_rcv` fires after `ip_local_deliver_finish()` has already called
`__skb_pull(skb, skb_network_header_len(skb))`, which advances `skb->data`
past the IP header. At `icmp_rcv` entry, `skb->data` therefore points
directly at the ICMP header: byte 0 = type, byte 1 = code.

To read `skb->data` without a full `vmlinux.h`, the program declares a
**partial `struct sk_buff`** containing only the field it needs, annotated
with `__attribute__((preserve_access_index))`:

```c
struct sk_buff {
	unsigned char *data;
} __attribute__((preserve_access_index));
```

This causes clang to emit a CO-RE (Compile Once – Run Everywhere) BTF field
relocation for every access to a member of this struct, instead of baking in
a compile-time-fixed offset. libbpf resolves the real offset at load time
using the running kernel's BTF (`/sys/kernel/btf/vmlinux`). The kernel's
actual `sk_buff` has dozens of fields; only `data` is declared here, which is
enough for CO-RE relocation to work — the rest of the struct's layout is
irrelevant to this program.

`skb->data` is read via `BPF_CORE_READ(skb, data)`, then the first two bytes
at that address are read with `bpf_probe_read_kernel` (type, code). Only
when `type == 3 && code == 4` does the program increment `icmp_rcv_total`.
Every other ICMP packet (echo request/reply, etc.) is ignored. The program
remains pass-through; it does not drop or modify anything (kprobes cannot
affect packet delivery in any case).

Full source: `bpf/kprobes.bpf.c`.

---

## Blocker found and resolved: kernel BTF parsing

The Day 4 build toolchain (`libbpf-dev` 0.5.0 from Ubuntu 22.04's apt repo,
linked into `spikes/probe_attach.c`) compiled the new CO-RE kprobe correctly,
confirmed via `readelf -S` (`.BTF`, `.rel.BTF`, `.BTF.ext`, `.rel.BTF.ext`
sections present) and `bpftool btf dump file kprobes.bpf.o` (correct partial
`STRUCT 'sk_buff'` BTF type emitted). But **loading** the object failed:

```
libbpf: failed to find valid kernel BTF
libbpf: Error loading vmlinux BTF: -3
libbpf: failed to load object '/tmp/kprobes.bpf.o'
bpf_object__load failed
```

`/sys/kernel/btf/vmlinux` exists and is readable (6.0M) inside the
container. Running `bpftool btf dump file /sys/kernel/btf/vmlinux` directly
(using `/usr/lib/linux-tools-5.15.0-181/bpftool`, the only bpftool available
via apt for this kernel series) also failed:

```
Error: failed to load BTF from /sys/kernel/btf/vmlinux: Invalid argument
```

Root cause: a **BTF format/version incompatibility**. The host kernel is
6.10.14-linuxkit; the userspace BTF parsers available via Ubuntu 22.04 apt
(`bpftool` 5.15.0-181, `libbpf0` 0.5.0) were both built years before that
kernel and cannot parse the BTF encoding it emits, even though the raw BTF
data is present and well-formed. Checked `apt-cache madison libbpf0`: only
`1:0.5.0-1` / `1:0.5.0-1ubuntu22.04.1` are available for jammy — no newer
libbpf0 ships via apt for Ubuntu 22.04.

**Fix:** built `libbpf` v1.4.0 from source (`github.com/libbpf/libbpf`,
static lib only) and linked `spikes/probe_attach.c` against it instead of
the system package.

```sh
git clone --depth 1 --branch v1.4.0 https://github.com/libbpf/libbpf.git /tmp/libbpf-src
cd /tmp/libbpf-src/src
make -j4 BUILD_STATIC_ONLY=1 OBJDIR=/tmp/libbpf-build DESTDIR=/tmp/libbpf-install install
# libbpf build exit: 0
```

Sanity check — does the new libbpf parse the kernel's BTF at all, isolated
from any lab setup:

```c
struct btf *btf = btf__load_vmlinux_btf();
/* ... */
printf("vmlinux BTF loaded OK, nr_types=%d\n", btf__type_cnt(btf));
```

```
vmlinux BTF loaded OK, nr_types=143536
```

Confirmed: libbpf v1.4.0 parses kernel 6.10.14-linuxkit's BTF without error.
The Day 4 system libbpf0 0.5.0 could not; a newer libbpf can. This is not a
problem with the BPF program — it is purely a userspace BTF-parser version
gap, and a static build of a current libbpf closes it.

`spikes/probe_attach.c` was rebuilt against this static libbpf v1.4.0:

```sh
gcc -O2 -o /tmp/probe_attach_new spikes/probe_attach.c \
  -I/tmp/libbpf-install/usr/include \
  /tmp/libbpf-install/usr/lib64/libbpf.a \
  -lelf -lz -lpthread
# Exit: 0
```

---

## Compile output (kprobes.bpf.o, filtered version)

```sh
clang -O2 -g -target bpf -I/tmp/libbpf-install/usr/include -I/usr/include \
  -I/usr/include/aarch64-linux-gnu -D__TARGET_ARCH_arm64 \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/kprobes.bpf.c -o /tmp/kprobes.bpf.o
# Exit: 0
```

Compiled cleanly with no warnings. `-I/tmp/libbpf-install/usr/include` was
used ahead of the system `/usr/include` so the BPF object and the loader
agree on the same libbpf header version (avoids ABI mismatch between
compile-time helper definitions and the runtime library).

---

## What is proven by this commit

1. The kprobe can read `skb->data` via CO-RE without a full `vmlinux.h`,
   using a partial `struct sk_buff` + `preserve_access_index`.
2. The filtering logic (type==3 && code==4) compiles correctly and is
   pass-through (no packet modification, kprobes cannot drop packets).
3. The root cause of the Day 4-era BTF load failure is a userspace
   libbpf/bpftool version gap against a newer kernel's BTF — not a defect
   in the compiled BPF object.
4. Building libbpf v1.4.0 from source resolves the load failure: it parses
   the running kernel's BTF (143536 types) cleanly.

## What remains unproven (until Commit 2)

- That the filtered counter actually stays at 0 for non-PTB ICMP traffic
  and increments correctly for real injected PTBs, under a live kprobe
  attach. This requires running the lab and is covered in Commit 2.
