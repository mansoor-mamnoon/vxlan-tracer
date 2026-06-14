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
- [ ] `tc_egress_vxlan0.bpf.c` — TC egress BPF for inner packet observation
- [ ] `tc_ingress_eth0.bpf.c` — TC ingress BPF for pre-netfilter PTB counting
- [ ] `kprobes.bpf.c` — ip_do_fragment kprobe + icmp_rcv fentry
       NOTE: icmp_send must use tracepoint:net:icmp_send on kernel 6.10+
- [ ] Go controller: clsact qdisc setup + BPF program attachment
- [ ] Go controller: map polling loop
- [ ] Diagnosis engine: MTU arithmetic + suppression detection
- [ ] Structured output (human-readable + JSON)
- [ ] `make smoke-small` and `make smoke-large` passing end-to-end with BPF loaded
- [ ] bpftrace ip_do_fragment.bt executed with field output (needs Lima VM + bpftrace 0.16+)

### V0 scope limitations

- IPv4 VXLAN only (UDP port 4789)
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
