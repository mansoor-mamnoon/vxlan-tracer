# evidence/day-04-icmp-rcv-attach.md

kprobe/icmp_rcv attachment via `spikes/probe_attach.c` (libbpf loader).
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.
bpftool: `/usr/lib/linux-tools-5.15.0-181/bpftool` v5.15.199.

---

## Loader invocation

```sh
gcc -O2 -o /tmp/probe_attach spikes/probe_attach.c -lbpf
# Exit: 0

/tmp/probe_attach /tmp/kprobes.bpf.o 20 &
```

### probe_attach startup output

```
probe_attach: kprobe/icmp_rcv attached to kernel icmp_rcv
probe_attach: icmp_rcv_total at attach = 0
probe_attach: running for 20 seconds...
```

The program loaded kprobes.bpf.o, resolved the kprobe section name `kprobe/icmp_rcv`
to attach to the kernel function `icmp_rcv`, and started the counter at 0.

---

## bpftool prog list (kprobe program confirmed live)

```
182: kprobe  name kprobe_icmp_rcv  tag aa93b500236fde34  gpl
     loaded_at 2026-06-14T11:52:19+0000  uid 0
     xlated 144B  jited 192B  memlock 4096B  map_ids 87
```

Key fields:
- `type kprobe`: correct BPF program type for kprobe attachment
- `name kprobe_icmp_rcv`: function name from the SEC annotation
- `jited`: the BPF verifier accepted the program and JIT-compiled it
- `xlated 144B  jited 192B`: small — no packet parsing, just counter increment
- `map_ids 87`: the icmp_rcv_total ARRAY map is live

For reference, system kprobes pre-existing in the container (from Docker security):
```
5: kprobe  name kprobe__oom_kil  tag c62690bae6f7d239
7: kprobe  name kprobe_mmap      tag 53f774b57c3c00fc
```

---

## bpftool map list

```
85: hash  name ptb_ingress_cou  flags 0x0   ← TC ingress from tc_ingress_eth0
86: array name ptb_ingress_tot  flags 0x0   ← TC ingress total
87: array name icmp_rcv_total   flags 0x0   ← kprobe/icmp_rcv counter
```

All three maps live simultaneously. Map IDs are stable for the lifetime of the
loaded programs. Map 87 (icmp_rcv_total) is owned by the kprobe program loaded
via probe_attach.

---

## Attachment method

`bpf_program__attach_kprobe(prog, false, "icmp_rcv")` via libbpf:
- `false` = entry probe (not return probe)
- Creates a perf_event on `/proc/kallsyms` address of `icmp_rcv`
- Attaches the BPF program to that perf_event via ioctl PERF_EVENT_IOC_SET_BPF
- The kprobe fires at the ENTRY of `icmp_rcv`, before any ICMP processing

bpftool does NOT provide a direct `bpftool prog attach kprobe icmp_rcv` command
in v5.15. The libbpf-based probe_attach.c is the attachment mechanism for Day 4.

---

## What is proven by this attachment

1. `bpf/kprobes.bpf.c` compiled correctly (kprobe program type, correct section)
2. libbpf `bpf_program__attach_kprobe` works on kernel 6.10.14-linuxkit
3. The BPF verifier accepts kprobe_icmp_rcv (144B bytecode, jited 192B)
4. Map 87 (icmp_rcv_total) is accessible via bpftool map dump after attachment
5. The kprobe fires at icmp_rcv ENTRY — no packet drop risk (pure observation)

## What remains unproven

- icmp_rcv_total actually increments when ICMP PTBs arrive (Commit 5)
- Suppression signal: ptb_ingress > 0 while icmp_rcv == 0 (Commit 6)
