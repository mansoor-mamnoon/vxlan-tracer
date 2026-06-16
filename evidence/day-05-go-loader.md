# Day 5: Go loader (commits 4-5)

## Design

`internal/loader` (Linux-only, `//go:build linux`) replaces the manual
`tc filter add` / `probe_attach` shell workflow with a single Go entry point,
`loader.Attach(cfg)`:

1. Resolve the overlay (`vxlan0`) and underlay (e.g. `veth1`) interfaces via
   `netlink.LinkByName`.
2. Ensure a `clsact` qdisc exists on both interfaces (`ensureClsact`), adding
   one if missing.
3. Load `tc_ingress_eth0.bpf.o`, mark `ptb_ingress_counts` and
   `ptb_ingress_total` for pinning, create the collection (which performs the
   pin), and attach the `tc_ingress_count_ptb` program as a direct-action TC
   filter at `HANDLE_MIN_INGRESS` on the underlay.
4. Load `tc_egress_vxlan0.bpf.o`, mark `flow_state` for pinning, attach
   `tc_egress_track_flow` at `HANDLE_MIN_EGRESS` on the overlay.
5. Load `kprobes.bpf.o`, mark `icmp_rcv_total` for pinning, attach
   `kprobe_icmp_rcv` to the `icmp_rcv` kernel function via
   `link.Kprobe("icmp_rcv", prog, nil)`.

All three objects are loaded against the same `--pin-dir`
(`/sys/fs/bpf/vxlan-tracer` by default), so all four maps end up pinned side
by side, as designed in `docs/map-lifecycle.md`.

`Attach` tears down anything already attached if a later step fails (no
half-attached state survives a failed call). `Close()` detaches the kprobe
link (the only thing that does not persist on its own) and closes the
collection file descriptors; TC filters and pinned maps intentionally remain,
matching the existing shell-attach behavior.

A `//go:build !linux` stub (`internal/loader/loader_other.go`) keeps
`go build ./...` and `go vet ./...` working on macOS — `Attach` simply
returns an error there.

`cmd/vxlan-tracer/main.go` was extended with `--pin-dir` and `--bpf-dir`
flags, calls `loader.Attach`, then waits for either `--duration` to elapse or
SIGINT/SIGTERM, then calls `Close()`.

Dependencies added: `github.com/cilium/ebpf v0.13.2`,
`github.com/vishvananda/netlink v1.2.1` (both pure Go, no cgo — confirmed by
successful `GOOS=linux GOARCH=arm64 go build` from macOS with no Linux
toolchain present).

## Verification (live test, Docker + network namespace lab)

Test script: builds the three BPF objects, runs `scripts/setup-bpf-fs.sh`,
runs `scripts/setup-netns.sh` (the same ns1/ns2/vxlan0 lab used since Day 2),
then runs the cross-compiled Go binary (`GOOS=linux GOARCH=arm64`) against
the live lab with `--duration 30s`.

### Bug 1: `ip netns exec` detaches the bpffs mount

First run failed at the pin step:

```
error: attach failed: load tc ingress object /tmp/bpfobjs/tc_ingress_eth0.bpf.o:
new collection: map ptb_ingress_counts: pin map to
/sys/fs/bpf/vxlan-tracer/ptb_ingress_counts: no such file or directory
```

`/sys/fs/bpf/vxlan-tracer` clearly existed (confirmed via `ls -la` from the
same shell that ran `setup-bpf-fs.sh`), so this was not a missing-directory
bug in the loader. Root cause: the test invoked the Go binary via
`ip netns exec ns1 ...`. `ip netns exec` unshares the *mount* namespace (not
just the network namespace) and remounts a fresh `sysfs` on `/sys` inside the
child process, which detaches the `bpf`-type mount at `/sys/fs/bpf` that
`setup-bpf-fs.sh` had created in the parent mount namespace. From the Go
process's point of view, `/sys/fs/bpf/vxlan-tracer` no longer exists, so the
`BPF_OBJ_PIN` syscall returns `ENOENT` — matching the exact error text seen.

Fix: invoke the binary with `nsenter --net=/var/run/netns/ns1 -- <binary>`
instead of `ip netns exec ns1 <binary>`. `nsenter` only joins the namespaces
explicitly requested; since only `--net` was given, the mount namespace (and
therefore the bpffs mount) is left untouched, while interface lookups
(`vxlan0`, `veth1`) still resolve inside `ns1` correctly.

This is a real, generally applicable finding for anyone attaching pinned BPF
maps from inside a network namespace, not just a quirk of this test harness —
recorded here so it is not silently "fixed by accident" in the test script
without explanation.

### Bug 2: program names in loadPinned did not match the compiled object

After fixing the mount-namespace issue, both ingress maps pinned
successfully, but attach then failed with:

```
error: attach failed: load tc ingress object /tmp/bpfobjs/tc_ingress_eth0.bpf.o:
program "tc_ingress_eth0" not found in object
```

`loader.go` looked up programs by the BPF *object file* name
(`tc_ingress_eth0`, `tc_egress_vxlan0`), but the actual ELF program name is
the C function name following `SEC("tc")`/`SEC("kprobe/icmp_rcv")`:
`tc_ingress_count_ptb`, `tc_egress_track_flow`, `kprobe_icmp_rcv`. Fixed the
two mismatched lookups in `loader.go` (`kprobe_icmp_rcv` was already
correct).

### Final successful run

```
vxlan-tracer 0.1.0-dev
overlay:  vxlan0
underlay: veth1
pin dir:  /sys/fs/bpf/vxlan-tracer
bpf dir:  /tmp/bpfobjs
attached: tc ingress, tc egress, kprobe/icmp_rcv; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobe (TC filters remain attached; maps remain pinned)
```

TC filters attached, confirmed via `tc filter show`:

```
$ ip netns exec ns1 tc filter show dev veth1 ingress
filter protocol all pref 1 bpf chain 0 handle 0x1 tc_ingress_eth0 direct-action not_in_hw id 310 tag 20bd2d524d2b4592 jited

$ ip netns exec ns1 tc filter show dev vxlan0 egress
filter protocol all pref 1 bpf chain 0 handle 0x1 tc_egress_vxlan0 direct-action not_in_hw id 311 tag 8d5c7a9a173ff918 jited
```

Maps pinned, all four present:

```
$ ls -la /sys/fs/bpf/vxlan-tracer/
-rw------- 1 root root 0 ... flow_state
-rw------- 1 root root 0 ... icmp_rcv_total
-rw------- 1 root root 0 ... ptb_ingress_counts
-rw------- 1 root root 0 ... ptb_ingress_total
```

(File size 0 in `ls` is expected — bpffs reports pinned BPF objects as
zero-length regular files; the actual map contents are accessed via the BPF
syscall, not read()/stat() size.)

After the Go process exited (clean `--duration 30s` timeout, exit code 0):
- Kprobe detached (`detached kprobe...` message printed, no error).
- All four pinned map files still present (maps outlive the process, as
  designed).
- TC filters still present on both interfaces (TC attachment is independent
  of the loader process, as designed — same behavior as the Day 3-4 shell
  workflow).

Raw logs: `/tmp/day5-commit4-5-test-v3.log` describes the final passing run;
two earlier attempts in the same session captured the two bugs above before
they were fixed (not committed as separate evidence — the failures and fixes
are fully described above instead, per the "do not hide failed verifier
attempts" instruction).

## What is proven

- The Go loader (`internal/loader`, using `cilium/ebpf` and
  `vishvananda/netlink`, no cgo, no libbpf dependency) can attach all three
  BPF programs (TC ingress, TC egress, kprobe) to a live VXLAN lab and pin
  all four maps under a stable bpffs path in one process invocation.
- The loader cross-compiles cleanly from macOS to Linux/arm64 and runs
  correctly against a real kernel inside Docker + network namespaces.
- TC filters and pinned maps both survive the loader process exiting, as
  designed; only the kprobe link (which has no independent persistence
  mechanism here) is torn down on `Close()`.
- `ip netns exec` is unsafe to combine with bpffs pinning due to its mount
  namespace unshare/remount behavior; `nsenter --net=...` is the correct way
  to run a BPF-pinning process inside a target network namespace.

## What remains unproven

- The loader has not yet been tested against a real PTB-suppression
  scenario (ping vs. PTB injection) — Commit 4/5 only proves attach/pin/
  detach mechanics, not correct counter values. That is deferred to the Go
  map reader (commit 6) and the unsuppressed/suppressed runs (commits 8-9).
- No reload/restart-with-existing-pinned-maps path has been exercised (the
  `LoadPinnedMap`-then-reuse branch in `cilium/ebpf` was hit implicitly on
  the second test run only because each Docker container starts fresh; a
  same-container reload test has not been done).
- Error handling for partially-pinned state (e.g. a stale pinned map left
  over from a crashed previous run, with an incompatible spec) is untested.
