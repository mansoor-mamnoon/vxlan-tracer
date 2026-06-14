# evidence/day-03-bpf-build.md

BPF compilation results from Day 3.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## tc_ingress_eth0.bpf.c

### First compile attempt — FAILED

```
clang -O2 -g -target bpf \
  -I/usr/include \
  -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o bpf/tc_ingress_eth0.bpf.o

bpf/tc_ingress_eth0.bpf.c:82:23: error: use of undeclared identifier 'IPPROTO_ICMP'
        if (iph->protocol != IPPROTO_ICMP)
                             ^
bpf/tc_ingress_eth0.bpf.c:114:28: error: use of undeclared identifier 'IPPROTO_UDP'
        if (orig_iph->protocol != IPPROTO_UDP)
                                  ^
2 errors generated.
```

**Root cause:** `IPPROTO_ICMP` and `IPPROTO_UDP` are defined in `linux/in.h`, which is
not transitively included by `linux/ip.h` in the BPF compilation context. Adding
`#include <linux/in.h>` fixed both errors.

### Second compile attempt — SUCCESS

```
clang -O2 -g -target bpf \
  -I/usr/include \
  -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o bpf/tc_ingress_eth0.bpf.o

Exit: 0
```

**Object file:** `bpf/tc_ingress_eth0.bpf.o` (18 KB)

**ELF sections:**
```
[ 3] tc                PROGBITS  AX   0x2e8 bytes  (BPF bytecode)
[ 4] .reltc            REL            0x30 bytes   (relocations)
[ 5] .maps             PROGBITS  WA   0x40 bytes   (map descriptors)
[ 6] license           PROGBITS  WA   0x4 bytes    ("GPL")
```

**BTF map symbols:**
```
16: ptb_ingress_counts  32B  OBJECT  GLOBAL  section .maps
17: ptb_ingress_total   32B  OBJECT  GLOBAL  section .maps
18: _license             4B  OBJECT  GLOBAL  section license
```

The `.maps` section contains two maps:
- `ptb_ingress_counts` — HASH, key=ptb_key (8B), value=ptb_val (28B), max_entries=1024
- `ptb_ingress_total`  — ARRAY, key=__u32 (4B), value=__u64 (8B), max_entries=1

The `tc` section contains the compiled BPF bytecode (0x2e8 = 744 bytes).
No compiler warnings were emitted.

### Fix applied to source

Added `#include <linux/in.h>` between `linux/if_ether.h` and `linux/ip.h` in
`bpf/tc_ingress_eth0.bpf.c`. This is the standard header providing `IPPROTO_*`
constants in the Linux BPF compilation context.

---

## tc_egress_vxlan0.bpf.c

Compilation documented in a separate evidence section after Commit 9.
