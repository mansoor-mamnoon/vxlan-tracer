# Roadmap

## V0 — Lab-validated prototype

Goal: detect and diagnose VXLAN MTU blackholes in a controlled network
namespace environment. No production deployment required.

### V0 components

- [x] Repository scaffold and docs
- [x] Lab topology (netns + veth + vxlan) — confirmed working on Docker linuxkit 6.10.14
- [x] bpftrace spike probes (ip_do_fragment, icmp_send, ptb_suppression)
- [x] MTU arithmetic checker with correct Go tests (8 tests pass)
- [x] linux-env-check.sh — PASS/WARN/FAIL pre-flight
- [x] inject_ptb.py — synthetic ICMP PTB injection via scapy
- [x] ip_do_fragment hook confirmed on kernel 6.10.14 (ftrace: 2 events/oversized-pkt)
- [x] DF=1 blackhole scenario confirmed (100% packet loss with df=set + stale MTU)
- [x] evidence/day-01.md, evidence/day-02.md, evidence/test-results.md
- [x] `tc_egress_vxlan0.bpf.c` — TC egress BPF for inner packet observation (Day 3)
- [x] `tc_ingress_eth0.bpf.c` — TC ingress BPF for pre-netfilter PTB counting (Day 3)
- [x] `kprobes.bpf.c` — icmp_rcv kprobe for post-netfilter PTB counting (Day 4)
       NOTE: icmp_send not a T symbol on 6.10.14; icmp_rcv used instead
       NOTE: currently counts all ICMP; needs CO-RE filtering for type=3 code=4 (Day 5)
- [x] PTB suppression detection: TC ingress > 0 AND icmp_rcv == 0 (Day 4, proven in lab)
- [x] scripts/diagnose-from-bpftool.sh — three-verdict combiner (Day 4)
- [x] docs/map-lifecycle.md — BPF map pinning rationale (Day 4)
- [x] icmp_rcv kprobe: CO-RE skb parsing to filter type=3 code=4 only (Day 5)
- [x] Map pinning under /sys/fs/bpf/vxlan-tracer/ with stable paths (Day 5)
- [x] Go controller: clsact qdisc setup + TC ingress/egress + kprobe attachment (Day 5)
- [x] Go controller: BPF link attachment for kprobe (replaces probe_attach.c) (Day 5)
- [x] Go controller: pinned-map reader (internal/bpfmap/pinned.go) (Day 5)
- [x] Diagnosis engine: MTU arithmetic + suppression detection (Go CLI, internal/diag/verdict.go) (Day 5)
- [x] End-to-end Go CLI verdict proven live: PTB_DELIVERED and PTB_SUPPRESSED both observed
      through the actual binary, not a shell script (Day 5)
- [x] Structured (JSON) output — `--json` flag; proven live for frag and PTB paths (Day 6)
- [x] ip_do_fragment observed through BPF map data rather than ftrace only (Day 6)
       NOTE: frag_events_total=6 for 3 large pings proven live; CO-RE skb->len read confirmed
       NOTE: VXLAN_FRAGMENTATION_OBSERVED verdict driven by BPF counter, not ftrace
- [x] `make smoke-small` and `make smoke-large` passing end-to-end with BPF loaded (Day 7)
- [ ] bpftrace ip_do_fragment.bt executed with field output (needs Lima VM + bpftrace 0.16+)
- [x] Exit-code contract: 0=verdict produced, 2=tool error; documented in docs/exit-codes.md (Day 7)
- [x] Idempotent TC attach (FilterList+FilterDel before FilterAdd; no "file exists" on rerun) (Day 7)
- [x] Idempotent map clearing (ClearPinned at start; --no-clear flag for debugging) (Day 7)
- [x] Automated scenario runner: 4/4 verdicts proven in single Docker run (Day 7)
- [x] Fragmentation verdict qualified: two-signal corroboration or conservative global disclaimer (Day 7)
- [x] frag_max_skb_len surfaced in JSON output (Day 7)
- [x] docs/reproducibility.md — Docker quickstart, capability requirements, known kernel behavior (Day 7)
- [x] make scenarios target for Docker end-to-end test (Day 7)
- [x] bpf_get_netns_cookie confirmed NOT available for kprobe/sched_cls on 6.10.14-linuxkit (Day 8)
       NOTE: verifier error captured; /proc/kallsyms confirms no wrapper for these program types
- [x] ip_do_fragment header parsing spike — skb->network_header inconsistent with route MTU cache (Day 8)
       NOTE: sometimes outer IP header, sometimes inner; VXLAN scoping via header parsing deferred
- [x] fragmentation_scope JSON field added — global_corroborated or global_unscoped (Day 8)
- [x] Scenario runner extended to 5/5 scenarios; second-run idempotency with route cache flush (Day 8)
- [x] Route/PMTU cache flush proven effective on 6.10.14-linuxkit (ip route flush cache) (Day 8)
- [x] build-linux-arm64, build-linux-amd64, package, test Makefile targets (Day 8)
- [x] install/uninstall Makefile targets with Linux-only guard and PREFIX support (Day 8)
- [x] docs/kernel-matrix.md — Docker does not change kernels; real VMs required for kernel testing (Day 8)
- [x] docs/fragmentation-scoping.md — five scoping options analyzed; two-signal chosen with evidence (Day 8)
- [x] docs/vm-validation.md — setup guide for Ubuntu 22.04/24.04 VMs; evidence checklist (Day 9)
- [x] scripts/preflight.sh — 20-check preflight (OS, kernel, BTF, bpffs, commands, symbols, scapy) (Day 9)
- [x] Makefile: frag_kprobes.bpf.o added to bpf target; preflight target added (Day 9)
- [x] scripts/run-scenarios.sh preflight guards — BPF_DIR, required commands, BTF, bpffs (Day 9)
- [x] Real VM validation: Ubuntu 22.04 5.15.0-181-generic aarch64 (Lima VM) — 5/5 PASS (Day 9)
       NOTE: first non-linuxkit kernel tested; identical verdicts and JSON fields
- [x] bpf_get_netns_cookie UNSUPPORTED confirmed on 5.15.0-181-generic (different error: "unknown func") (Day 9)
- [x] skb->network_header inconsistency more severe on 5.15: inner IP even on first run (Day 9)
- [x] ip route flush cache effective on 5.15.0-181-generic (Day 9)
- [x] Two kernels in validated matrix: 6.10.14-linuxkit and 5.15.0-181-generic (Day 9)
- [x] preflight.sh capability checks: CAP_BPF probe, netns probe, clsact qdisc probe,
       unprivileged_bpf_disabled, perf_event_paranoid — failure categories: DEPENDENCY/PRIVILEGE/KERNEL/ENVIRONMENT (Day 10)
- [x] GitHub Actions x86_64 CI probe: ubuntu-22.04 runner on x86_64 6.8.0-1052-azure (Day 10)
- [x] x86_64 BPF compilation fix: -D__x86_64__ in Makefile CFLAGS for glibc stubs-32.h issue (Day 10)
- [x] Real x86_64 validation: 6.8.0-1052-azure (GitHub Actions) — 5/5 PASS (Day 10)
       NOTE: first x86_64 run; PT_REGS_PARM1 ctx->di confirmed; all JSON fields identical to aarch64
- [x] Three kernels in validated matrix: 6.10.14-linuxkit, 5.15.0-181-generic, 6.8.0-1052-azure (Day 10)
- [x] docs/x86-cloud-validation.md — cloud VM setup guide for x86_64 (Day 10)
- [x] Makefile arch detection hardened: explicit FAIL for unsupported arch; bpf_target logged (Day 10)
- [x] docs/kernel-matrix.md updated: real tested data only; entry 3 added for x86_64 (Day 10)
- [x] VXLAN UDP port runtime-configurable via BPF config map + --vxlan-port CLI flag (Day 11)
       NOTE: default changed from 4789 to 0 (auto-detect from overlay interface via rtnetlink)
- [x] internal/netlink.DetectVXLAN: reads dstport and VNI from overlay interface via rtnetlink (Day 11)
       NOTE: proven on 5.15.0-181-generic with both port-4789 and port-8472 netns interfaces (Day 12)
- [x] vxlan_port and vxlan_vni JSON output fields (Day 11)
- [x] inject_ptb.py --vxlan-port argument (default 4789) (Day 11)
- [x] docs/kubernetes-validation.md: two-node requirement, proof checklist, CNI notes (Day 11)
- [x] k8s/ manifests: namespace + traffic-pods with podAntiAffinity for cross-node enforcement (Day 11)
- [x] Non-4789 port (8472) end-to-end: PTB_DELIVERED and PTB_SUPPRESSED proven in netns lab on 5.15.0-181-generic (Day 12)
       NOTE: netns lab only — not a real k3s/flannel node
- [x] 6/6 scenario suite proven: scenarios 1–5 unaffected by vxlan_config map; scenario 6 asserts vxlan_port=8472 in JSON (Day 12)
- [x] k3s two-node validation: NOT RUN — no two-node cluster available from macOS dev env (Day 12)
- [x] Stale BPF object guard: loader fails closed when vxlan_config map is missing (error + fix instructions) (Day 13)
       NOTE: previously returned nil silently → attached with wrong port filter
- [x] Unit tests for fail-closed loader: TestWriteVXLANPortToMapsMissing, TestWriteVXLANPortToMapsMissingPort0 (Day 13)
- [x] make clean-bpf, make bpf-verify targets; bpf-verify uses readelf -s (symbol table, not section headers) (Day 13)
- [x] Stale macOS BPF object deleted (17936 bytes, Jun 14, pre-vxlan_config) (Day 13)
- [x] preflight.sh BPF object freshness check (same readelf -s approach) (Day 13)
- [x] CI: clean-bpf + bpf-verify before compile; 6-scenario suite with port 8472 (Day 13)
- [x] x86_64 6/6 pass on 6.8.0-1059-azure (GitHub Actions run 27851298262) including port 8472 (Day 13)
       NOTE: job conclusion PASS; preflight ENVIRONMENT annotation from dummy interface restriction (expected)
- [x] Four kernels in validated matrix: 6.10.14-linuxkit, 5.15.0-181-generic, 6.8.0-1052-azure, 6.8.0-1059-azure (Day 13)
- [x] docs/release-checklist.md — pre-release gate items (Day 13)
- [x] docs/forbidden-claims.md: added entry 15 distinguishing netns-lab from CNI validation (Day 13)
- [x] scripts/demo.sh: self-contained stale-MTU VXLAN fragmentation demo; make demo target (Day 14)
- [x] printHuman(): structured human-readable output — Verdict/Evidence/Recommendation/Scope sections (Day 14)
- [x] Per-arch release packages: vxlan-tracer-linux-{amd64,arm64}.tar.gz + checksums.sha256 (Day 14)
- [x] Version metadata via -ldflags: version/commit/buildDate; --version shows all three (Day 14)
- [x] LICENSE: MIT, Copyright 2026 Mansoor Mamnoon (Day 14)
- [x] README: plain-English symptom, demo command, build/install section, updated status table (Day 14)
- [ ] Real two-node k3s/flannel validation: cross-node pod traffic on flannel.1 port 8472 (V1)
- [ ] CNI validation: PTB_DELIVERED or VXLAN_FRAGMENTATION_OBSERVED confirmed on real CNI traffic (V1)

### V0 scope limitations

- IPv4 VXLAN only; VXLAN UDP port is configurable (default: auto-detect; was hardcoded 4789 until Day 11)
- Single overlay + single underlay interface pair
- No per-VNI attribution (VNI = 0 in V0)
- No active PMTUD probe synthesis
- Lab-validated only; no production deployment

## V1 — PTB suppression detection and CI

Goal: robust suppression detection, CI test suite, per-VNI attribution.

- [ ] PTB suppression verdict with rolling-window comparison
- [ ] per-VNI attribution via rtnetlink startup query
- [ ] CI test suite: three netns scenarios (no blackhole, blackhole+PTB,
      blackhole+suppression)
- [ ] ip_do_fragment fallback: `__ip_finish_output` kprobe for kernels where
      ip_do_fragment is inlined
- [ ] kernel version matrix: 5.10, 5.15, 5.17, 6.1, 6.5

## V2 — Out of scope (future)

- IPv6 underlay (ICMPv6 Type 2, icmpv6_rcv)
- Active PMTUD probe synthesis (raw socket + binary search)
- Non-VXLAN tunnel types (Geneve, GRE, WireGuard, IPIP)
- Continuous monitoring daemon mode
- Kubernetes integration (DaemonSet, per-node metrics)

## Non-goals (permanent)

See docs/forbidden-claims.md. The following will never be claimed:

- XDP egress
- Zero overhead
- Production validation without actual production runs
- Inner 5-tuple from ICMP PTB
- Support for tunnel types not listed under V2
