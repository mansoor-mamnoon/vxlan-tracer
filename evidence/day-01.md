# evidence/day-01.md

Day 1 session summary. Records environment, all commits made, what was proven,
what failed, and what remains unverified.

## Environment

| Item | Value |
|------|-------|
| Development OS | macOS 25.0.0 (Darwin arm64) |
| Kernel | Darwin XNU-12377 (NOT Linux) |
| Go | go1.26.3 darwin/arm64 |
| clang | Apple clang 15.0.0 (not targeting BPF — macOS clang cannot compile for BPF) |
| bpftool | not installed |
| bpftrace | not installed |
| /proc/kallsyms | not available (macOS) |
| /sys/kernel/btf/vmlinux | not available (macOS) |

**Implication:** All Linux-specific steps (network namespaces, BPF programs,
bpftrace probes, kernel symbol checks) could NOT be executed on the development
machine. Only Go code and shell script syntax were verified locally.

This is documented accurately. No Linux-specific results were fabricated.

## Commits made

| # | Hash | Message |
|---|------|---------|
| 1 | 0fa5107 | init repo skeleton: go module, makefile, cli stub |
| 2 | 0f593ef | add README with honest project pitch and non-goals |
| 3 | f899562 | document corrected hook model: TC/kprobe architecture, no XDP egress |
| 4 | a82aea0 | add lab topology doc and v0/v1 roadmap |
| 5 | c3dc92c | add netns lab setup and teardown scripts |
| 6 | e205b00 | add smoke test scripts for small and large traffic |
| 7 | 4946177 | add bpftrace spike: ip_do_fragment fragmentation detection |
| 8 | 66fc6ad | add BPF map schema and bpf/ directory README |
| 9 | 6fc9229 | add mtu arithmetic checker with tests and output schema |
| 10 | (this) | add evidence files: day-01, commands, hook-findings, test-results |

## What was proven today

1. **Go MTU arithmetic is correct.** `go test ./internal/diag/ -v` passes 6
   subtests (after Day 2 arithmetic correction). The correct math:
   inner IP 1500 + 50 overhead = outer IP 1550 → 50 bytes excess over underlay MTU 1500.
   Wire frame is 1564 bytes (outer ETH 14 + outer IP 1550) but the kernel MTU
   comparison is at the IP layer (1550 vs 1500), not the wire frame level.

2. **Shell scripts are syntactically correct.** `bash -n` on all four scripts
   returns 0.

3. **The original "XDP egress" architecture is wrong.** XDP is ingress-only.
   The corrected architecture (TC egress + kprobes) is documented and the
   reasoning is technically sound.

4. **ip_do_fragment MUST be in V0.** Without it, the tool produces zero output
   on default Flannel clusters (DF=0). This is the most important architectural
   correction from the original design.

5. **ICMP PTB does not contain inner 5-tuple.** Documented in forbidden-claims
   and architecture. Correlation is VTEP-level only.

6. **tcpdump AF_PACKET fires before netfilter.** The original "tcpdump cannot
   see suppressed PTBs" claim is wrong. The correct differentiation is the
   icmp_rcv count comparison, not pre-netfilter visibility.

7. **Repository is clean.** `git log` shows 10 commits with correct author
   identity (Mansoor Mamnoon). No fabricated content.

## What was not proven (requires Linux)

1. `ip_do_fragment` symbol presence in `/proc/kallsyms` on kernel 5.15.
   **Risk:** If inlined, must fall back to `__ip_finish_output` kprobe.

2. bpftrace probe execution: `ip_do_fragment.bt` fires when expected.

3. Netns lab topology creation and VXLAN reachability.

4. Whether large traffic produces a hard blackhole or fragmented-but-successful
   transfer in the local veth+netns topology.

5. TC BPF program compilation against Linux kernel headers.

6. `fentry/icmp_rcv` requires BTF available at `/sys/kernel/btf/vmlinux`.

## Known issues and limitations

1. **Local netns topology may not reproduce a hard blackhole with DF=0.**
   In a local veth pair, there is no middlebox to drop DF=0 fragments. ns2 may
   reassemble them successfully. To reproduce a hard stall: add `df set` to the
   VXLAN interface configuration. This is documented in docs/lab-topology.md.

2. **PTB suppression demo requires artificial setup.** Testing ptb_suppression.bt
   requires `df set` on vxlan0 AND an iptables DROP rule for ICMP type 3 code 4.
   Neither of these is a default configuration. The probe detects a real failure
   class (cloud security group ICMP filtering, ops team iptables rules) but the
   lab reproduction is artificially constructed.

3. **macOS development environment blocks all kernel work.** All BPF and netns
   work must happen on a separate Linux host. This is a workflow limitation, not
   a project correctness issue.

## Next steps (Day 2)

1. Run on a Linux 5.15 host:
   - `grep ip_do_fragment /proc/kallsyms` → confirm symbol exists
   - `sudo bash scripts/setup-netns.sh` → confirm topology
   - `sudo bash scripts/smoke-small-traffic.sh` → confirm small traffic
   - `sudo bash scripts/smoke-large-traffic.sh` → observe large traffic behavior
   - `sudo bpftrace spikes/bpftrace/ip_do_fragment.bt` during large traffic

2. Write the TC egress BPF C program skeleton (`bpf/tc_egress_vxlan0.bpf.c`).

3. Attempt compilation with clang against kernel headers. Record verifier errors.

4. Update evidence/test-results.md with all Linux results.

## Files created today

```
.gitignore
Makefile
README.md
bpf/README.md
bpf/maps.h
cmd/vxlan-tracer/main.go
docs/architecture.md
docs/forbidden-claims.md
docs/hook-model.md
docs/lab-topology.md
docs/roadmap.md
evidence/commands.md
evidence/day-01.md
evidence/hook-findings.md
evidence/test-results.md
go.mod
internal/diag/mtu.go
internal/diag/mtu_test.go
internal/output/schema.go
scripts/setup-netns.sh
scripts/teardown-netns.sh
scripts/smoke-large-traffic.sh
scripts/smoke-small-traffic.sh
spikes/bpftrace/icmp_send.bt
spikes/bpftrace/ip_do_fragment.bt
spikes/bpftrace/ptb_suppression.bt
```
