# evidence/day-05-bpf-fs-setup.md

Day 5 Commit 3: map pinning filesystem setup. Verifies `scripts/setup-bpf-fs.sh`
mounts bpffs at `/sys/fs/bpf` and creates `/sys/fs/bpf/vxlan-tracer/` as the
pin directory, idempotently.

Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## First run (no prior bpffs mount)

```
$ mount | grep bpf
no bpf mount yet

$ sudo bash scripts/setup-bpf-fs.sh
[setup-bpf-fs] Checking bpffs mount at /sys/fs/bpf...
[setup-bpf-fs] Mounting bpffs...
[setup-bpf-fs] bpffs mounted.
[setup-bpf-fs] Creating pin directory /sys/fs/bpf/vxlan-tracer...
[setup-bpf-fs] Done.

Pinned map paths (once the loader attaches and pins):
  /sys/fs/bpf/vxlan-tracer/ptb_ingress_counts   (per-VTEP-pair PTB counts, tc_ingress_eth0)
  /sys/fs/bpf/vxlan-tracer/ptb_ingress_total    (global PTB-at-ingress total, tc_ingress_eth0)
  /sys/fs/bpf/vxlan-tracer/icmp_rcv_total       (post-netfilter filtered PTB total, kprobes)
  /sys/fs/bpf/vxlan-tracer/flow_state           (per-flow max inner/outer IP len, tc_egress_vxlan0)

Inspect with: bpftool map dump pinned /sys/fs/bpf/vxlan-tracer/<name>
--- exit: 0

$ mount | grep bpf
bpf on /sys/fs/bpf type bpf (rw,relatime)

$ ls -la /sys/fs/bpf/vxlan-tracer/
total 0
drwxr-xr-x 2 root root 0 Jun 16 05:45 .
drwxrwxrwt 3 root root 0 Jun 16 05:45 ..
```

---

## Second run (idempotency check)

```
$ sudo bash scripts/setup-bpf-fs.sh
[setup-bpf-fs] Checking bpffs mount at /sys/fs/bpf...
[setup-bpf-fs] bpffs already mounted.
[setup-bpf-fs] Creating pin directory /sys/fs/bpf/vxlan-tracer...
[setup-bpf-fs] Done.
--- exit: 0
```

No error on re-mount detection (`mount | grep` check short-circuits the
`mount -t bpf` call), and `mkdir -p` is naturally idempotent for the pin
directory.

---

## What is proven

1. `scripts/setup-bpf-fs.sh` correctly mounts bpffs when not already mounted,
   and detects an existing mount without attempting a duplicate mount.
2. The pin directory `/sys/fs/bpf/vxlan-tracer/` is created with correct
   permissions (root-owned, `drwxr-xr-x`).
3. The script is safe to run multiple times in sequence (required since it
   will run at the start of every `vxlan-tracer run` invocation).
4. The four pinned-map paths planned in `docs/map-lifecycle.md` are now
   documented consistently in both the design doc and the script's own
   output.

## What remains unproven

- That the Go loader (Commit 4) actually pins maps into this directory.
  The directory exists and is ready, but nothing pins into it yet — this
  commit only proves the filesystem prerequisite, not the pinning itself.
