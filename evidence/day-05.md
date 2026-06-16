# Day 5: Go-driven prototype with pinned maps and filtered counters

**Goal:** turn the Day 4 proof (TC ingress + icmp_rcv counting, manually
compared via bpftool) into a stable Go-driven prototype: filter icmp_rcv to
real PTBs only, pin all maps under a stable path, attach everything from a
Go binary instead of libbpf C tooling and shell scripts, read the pinned
maps from Go, and print a correct verdict — with no bpftool, no shell
script, and no manual counter comparison in the diagnostic path itself.

## Commits

| # | Hash | What was added |
|---|------|-----------------|
| 1 | `dcf1c5e` | Filter `icmp_rcv` kprobe to ICMP type=3/code=4 only via CO-RE skb parsing |
| 2 | `f294b49` | Verify filtered `icmp_rcv_total`: 0 across 5 pings, 5 after 5 injected PTBs |
| 3 | `52b9d74` | Map pinning design and `/sys/fs/bpf/vxlan-tracer/` filesystem setup |
| 4 | `a5bbc7c` | Go loader skeleton (`internal/loader`): clsact + TC ingress/egress + kprobe attach, map pinning |
| 5 | `97632ea` | Verify Go loader attach path live; root-caused and fixed two real bugs (see below) |
| 6 | `be6b408` | Go pinned-map reader (`internal/bpfmap/pinned.go`) with struct-layout safety-net tests |
| 7 | `7addbfa` | Diagnosis logic (`internal/diag/verdict.go`): 5-verdict precedence system |
| 8 | `98ec692` | Run unsuppressed PTB test through the Go reader — verdict `PTB_DELIVERED` |
| 9 | `fcf8438` | Run suppressed PTB test through the Go reader — verdict `PTB_SUPPRESSED` |
| 10 | (this commit) | Day 5 synthesis: evidence, hook findings, roadmap, README status |

## BPF programs active during Day 5 tests

```
tc_ingress_count_ptb   SEC("tc")           on veth1 (underlay) ingress
tc_egress_track_flow   SEC("tc")           on vxlan0 (overlay) egress
kprobe_icmp_rcv         SEC("kprobe/icmp_rcv") CO-RE filtered to ICMP type=3/code=4
```

All three pass-through (`TC_ACT_OK` / no skb mutation). Maps pinned:
`ptb_ingress_counts`, `ptb_ingress_total`, `icmp_rcv_total`, `flow_state`.

## Proof 1: filtered icmp_rcv distinguishes ping from PTB

Built libbpf v1.4.0 from source (apt's v0.5.0 cannot parse this kernel's BTF
encoding — see hook-findings.md Finding 15) and added `preserve_access_index`
CO-RE struct access to read ICMP type/code from the skb inside the kprobe.

```
5 pings:        icmp_rcv_total = 0
5 injected PTBs: icmp_rcv_total = 5
```

`icmp_rcv_total` can now be trusted to mean "PTBs observed post-netfilter,"
not "all ICMP traffic." This removes the Day 4 caveat that the counter was
lab-only.

## Proof 2: Go loader attaches everything and pins maps

`internal/loader.Attach` replaces the C `probe_attach.c` + shell-script flow:
it sets up a clsact qdisc, attaches both TC programs, attaches the kprobe via
a BPF link, and pins all 4 maps under `/sys/fs/bpf/vxlan-tracer/` — confirmed
via `tc filter show` and `ls -la /sys/fs/bpf/vxlan-tracer/` after the loader
attached.

Two real bugs were found and fixed during this work, both documented
transparently rather than hidden:

1. **`ip netns exec` detaches the bpffs mount.** It unshares the mount
   namespace and remounts a fresh `/sys` in the child process before running
   the command, breaking `BPF_OBJ_PIN` with a misleading `ENOENT` even though
   the pin directory is visible from the parent shell. Fixed by using
   `nsenter --net=/var/run/netns/<ns> -- <cmd>` instead, which only joins the
   network namespace and leaves the mount namespace (and bpffs) untouched.
2. **ELF program names are the C function name after `SEC(...)`, not the
   object file's base name.** The loader's first attempt looked up
   `tc_ingress_eth0` / `tc_egress_vxlan0` and failed with
   `program "tc_ingress_eth0" not found in object`. Fixed by using the actual
   function names: `tc_ingress_count_ptb`, `tc_egress_track_flow`.

Both are detailed in `evidence/day-05-go-loader.md` and
`evidence/hook-findings.md` (Findings 16–17).

## Proof 3: Go CLI prints the correct verdict for both branches, live

`internal/bpfmap/pinned.go` reads the 4 pinned maps directly via cilium/ebpf
(pure Go, no cgo/libbpf dependency at runtime). `internal/diag/verdict.go`
turns the observation into one of 5 verdicts, with direct PTB-counter
evidence always outranking static MTU checks.

**Run A — no suppression (`evidence/day-05-unsuppressed-go.md`):**
```
verdict: PTB_DELIVERED
5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv...
```

**Run B — iptables DROP rule on ICMP type=3/code=4 (`evidence/day-05-suppressed-go.md`):**
```
verdict: PTB_SUPPRESSED
5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: ...
```
Independently cross-checked by iptables' own packet counter (5 pkts / 280
bytes matched the DROP rule), read by a completely separate tool from the
Go binary's own pinned-map read.

Both runs used only the compiled Go binary plus test-harness orchestration
(starting/stopping the lab, injecting PTBs) — no bpftool, no shell-based
diagnosis script, no manual counter comparison.

## What is now proven

- `icmp_rcv_total` means "PTBs observed post-netfilter," not "all ICMP" —
  the Day 4 caveat is resolved.
- A single Go binary can attach TC ingress, TC egress, and the icmp_rcv
  kprobe; pin all 4 maps under a stable path; and detach cleanly, all
  confirmed live against a real kernel.
- The same Go binary can read its own pinned maps and print a verdict that
  correctly distinguishes "PTB delivered" from "PTB suppressed" — both
  branches proven live, not just designed.
- Two previously-undocumented operational pitfalls (mount-namespace
  interaction with `ip netns exec`, ELF program name vs. file name mismatch)
  are now documented with root cause and fix, reusable beyond this project.
- The struct layouts the Go reader assumes for raw map marshaling
  (`ptb_key`/`ptb_val`/`flow_key`/`flow_val`) are protected by
  `unsafe.Sizeof` tests against silent drift from `bpf/maps.h`.

## What remains unproven

- `ip_do_fragment` is still observed only via ftrace, not via a BPF map —
  the DF=0 fragmentation-blackhole scenario (the common case on default
  Flannel/Calico VXLAN) has no Go-CLI-visible signal yet.
- Only one suppression mechanism (iptables DROP) has been tested. Other
  mechanisms (nftables, conntrack, security modules) are not distinguished.
- No JSON/structured output yet — only human-readable text.
- No automated CI test suite; all proof so far is manual Docker runs.
- `bpftool` was unavailable in the Day 5 test containers, so only one
  independent cross-check tool (iptables counters) was available instead
  of two for the suppressed-path verification.
- No test of reload/restart behavior while a suppression condition is
  ongoing (maps are designed to persist independently of the loader
  process per the pinning design, but this was not explicitly re-verified
  this Day).

## Has the project crossed from "hook proof" to "diagnostic proof"?

Yes. Day 4 proved the underlying kernel hooks work and that a human, using
bpftool and a shell script, could compare two counters and reach the right
conclusion. Day 5 proves the actual `vxlan-tracer` Go binary — the artifact
users would actually run — does this itself: attach, observe, read its own
state, diagnose, and report, with no external tooling in the diagnostic
path. This is the first true CLI-level diagnostic proof for this project.

## Day 6 focus (next 10 commits)

| # | Focus |
|---|-------|
| 1 | Add an `ip_do_fragment` kprobe (BPF map, not ftrace) for the DF=0 fragmentation path |
| 2 | Pin and wire the new map into the Go loader/reader |
| 3 | Extend `diag.Observation`/`Diagnose` to use real fragmentation counts instead of the static MTU-only check |
| 4 | Verify the DF=0 fragmentation scenario live through the Go CLI (no PTB, just silent fragmentation) |
| 5 | Add `--json` structured output mode |
| 6 | Add an explicit, documented exit-code contract (e.g. 0=no issue, 1=blackhole detected, 2=error) |
| 7 | Write a minimal CI script that runs the three core netns scenarios (healthy, PTB-delivered, PTB-suppressed) against a real kernel |
| 8 | Add `--duration 0` / continuous polling mode design (still pass-through, no daemon yet) |
| 9 | Review and tighten `docs/forbidden-claims.md` against the new fragmentation verdict wording |
| 10 | Day 6 synthesis: evidence, roadmap, README updates |
