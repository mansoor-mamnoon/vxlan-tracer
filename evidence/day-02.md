# evidence/day-02.md

Day 2 session summary. Records environment, commits made, what was proven,
what failed, and what remains unverified.

## Environment

| Item | Value |
|------|-------|
| Development OS | macOS 25.0.0 (Darwin arm64) |
| Linux host | Docker Desktop 28.3.2, kernel 6.10.14-linuxkit aarch64 |
| Container | ubuntu:22.04, --privileged |
| Go | go1.26.3 darwin/arm64 |
| bpftrace | 0.14.0 (broken on linuxkit — see evidence/day-02-bpftrace.md) |
| clang | 14.0.0 (ubuntu:22.04) |
| iproute2 | 5.15.0 |
| scapy | 2.7.0 (pip3 install scapy) |

## Commits made (Day 2)

| # | Hash | Message |
|---|------|---------|
| D2-1 | 35ddbfa | fix MTU arithmetic: outer IP exceeds MTU by 50 bytes, not 64; wire frame is 1564 |
| D2-2 | 934be2c | add linux-env-check.sh: PASS/WARN/FAIL pre-flight for kernel symbols and tools |
| D2-3 | 1f48abb | run Linux env check via Docker: ip_do_fragment confirmed T symbol; icmp_send tracepoint-only on 6.10 |
| D2-4 | cb22e31 | fix setup-netns.sh for kernel 6.10 MTU enforcement; run lab setup in Docker |
| D2-5 | 648db36 | small traffic smoke test: 5/5 pings pass, 0 ip_do_fragment events confirmed via ftrace |
| D2-6 | 42f3f29 | large traffic smoke test: 20 ip_do_fragment events in 10 pings via raw ftrace |
| D2-7 | ac31b70 | document bpftrace 0.14 failure on linuxkit: linux/types.h missing; ftrace kprobe is the workaround |
| D2-8 | e1e4f5f | add inject_ptb.py: scapy-based synthetic ICMP PTB injection for suppression testing |
| D2-9 | 08df46a | PTB suppression test: DF=1 blackhole confirmed; locally-generated PTBs bypass iptables INPUT |
| D2-10 | (this) | day 2 synthesis: env check, lab topology, traffic tests, ftrace evidence documented |

## What was proven today

### 1. ip_do_fragment is present as a T symbol on kernel 6.10.14-linuxkit

```
ffff800080ff71d8 T ip_do_fragment
```

The primary kernel hook for DF=0 VXLAN fragmentation detection is kprobeable.
Confirmed in `/proc/kallsyms` inside a Docker privileged container.

### 2. ip_do_fragment fires on every oversized outer VXLAN packet (real Linux evidence)

Raw ftrace kprobe on ip_do_fragment: **20 events for 10 large pings** (2 per ping).
Each 1438-byte outer IP packet (inner 1388B + overhead 50B) exceeds the 1400-byte
underlay MTU and triggers ip_do_fragment. The ftrace event confirms entry at
`ip_do_fragment+0x0/0x508` — the function is not inlined on this kernel.

### 3. Small traffic produces zero ip_do_fragment events

Baseline confirmed: small ping (payload 40B → inner IP 68B → outer IP 118B)
produces 0 ip_do_fragment events and 0% packet loss. The tool must not report
fragmentation for correctly-sized traffic.

### 4. icmp_send is NOT a kprobeable T symbol on kernel 6.10.14

```
grep -E '^[0-9a-f]+ T icmp_send$' /proc/kallsyms  →  (no output)
```

icmp_send exists only as tracepoint infrastructure (`__traceiter_icmp_send` T,
`__probestub_icmp_send` T, `__bpf_trace_icmp_send` t). The bpftrace probe
`spikes/bpftrace/icmp_send.bt` was updated to document this and provide a
`tracepoint:net:icmp_send` alternative.

### 5. DF=1 blackhole scenario confirmed

With `df set` on vxlan0 and stale MTU (vxlan0=1450, underlay=1400):
- Large pings: **100% packet loss** (outer IP 1438B > 1400 with DF=1)
- Small pings: **0% packet loss** (outer IP 118B, no issue)

This reproduces the PTB-variant of the VXLAN MTU bug.

### 6. MTU arithmetic in Go is correct (all 8 tests pass)

- `ProjectedOuterIPLen(1500)` = 1550 (what kernel compares vs MTU)
- `ProjectedWireFrameLen(1500)` = 1564 (outer ETH 14 + outer IP 1550; informational)
- `MaxSafeInnerIPLen(1500)` = 1450 (not 1436; outer ETH is not in MTU)
- `CheckMTU(1500, 1500)` → ExcessBytes=50 (not 64)

### 7. Alternative blackhole topology works on kernel 6.10+

Kernel 6.10.14 enforces correct vxlan0 MTU at creation time (rejects values above
`underlay_mtu - 50`). The alternative: create vxlan0 at underlay=1500 (kernel sets
vxlan0=1450), then reduce underlay to 1400. Kernel does not auto-adjust vxlan0.
Lab topology created successfully with this approach.

### 8. Locally-generated PTBs bypass iptables INPUT chain

For the DF=1 scenario, the kernel generates PTBs in response to its own outgoing
packets. These take the loopback/local-delivery path and do NOT traverse netfilter
INPUT. The vxlan-tracer suppression detection is designed for externally-arriving
PTBs (from cloud fabric/middlebox), not this local case. inject_ptb.py provides
synthetic external PTBs to test the correct path.

## What was not proven (blockers documented)

### 1. bpftrace probe execution with skb field access

bpftrace 0.14.0 on ubuntu:22.04 cannot run on linuxkit 6.10.14 (missing
`linux/types.h` in embedded include path; see evidence/day-02-bpftrace.md).
The `outer_ip_len`, `dev_mtu`, and `ip_excess` fields in `ip_do_fragment.bt`
were not printed in actual execution. Raw ftrace confirmed the function fires;
field values are the remaining gap.

**Fix:** Lima VM or cloud VM with bpftrace 0.16+ and matching kernel headers.
See docs/linux-dev-environment.md for options.

### 2. TC ingress BPF program on underlay (pre-netfilter PTB count)

Not yet implemented. This is the first half of the suppression signal.
Without it, inject_ptb.py's synthetic PTBs arrive at ns1 but there is no
BPF hook to count them before iptables. Implementing this BPF C program
(`bpf/tc_ingress_eth0.bpf.c`) is the Day 3 primary goal.

### 3. TC egress BPF program on vxlan0 (inner packet observation)

Not yet implemented. This is the overlay-side hook for reading inner IP
5-tuples and packet sizes before VXLAN encapsulation.

### 4. fentry/icmp_rcv BPF program

Not yet implemented. This is the post-netfilter PTB count hook.
BTF is available (`/sys/kernel/btf/vmlinux` present), so fentry should work
once a compatible clang+kernel-headers environment is available.

## Known issues and limitations

1. **Docker linuxkit is not a suitable bpftrace host** for the spike probes.
   Use Lima VM or a cloud VM with matching kernel headers. See
   docs/linux-dev-environment.md.

2. **Local veth+netns topology reassembles VXLAN fragments.** In production,
   cloud fabric drops VXLAN UDP fragments silently. The ip_do_fragment events
   confirm fragmentation is happening; whether those fragments are dropped
   depends on the underlay fabric, not the BPF hook.

3. **inject_ptb.py scapy PTB needs TC ingress BPF to complete the test.**
   The synthetic PTB can be sent from ns2 and will arrive at ns1. But without
   TC ingress BPF on veth1 in ns1, there is no hook to count it before iptables.

4. **Kernel 6.10.14 icmp_send tracepoint not discoverable by bpftrace 0.14.**
   Even if bpftrace worked, `tracepoint:net:icmp_send` would not be available
   via bpftrace 0.14's event discovery mechanism. bpftrace 0.16+ required.

## Files created or modified today

```
docs/linux-dev-environment.md     (new)
evidence/day-02-linux-env.md      (new)
evidence/day-02-lab-setup.md      (new)
evidence/day-02-traffic.md        (new)
evidence/day-02-ftrace.md         (new)
evidence/day-02-bpftrace.md       (new)
evidence/day-02-ptb.md            (new)
evidence/day-02.md                (this file)
evidence/commands.md              (updated: inject_ptb.py usage added)
internal/diag/mtu.go              (updated: arithmetic corrected)
internal/diag/mtu_test.go         (updated: tests corrected)
scripts/setup-netns.sh            (updated: alternative topology approach)
scripts/linux-env-check.sh        (new)
spikes/bpftrace/icmp_send.bt      (updated: kprobe limitation + tracepoint alternative)
spikes/inject_ptb.py              (new)
[+10 other files updated for MTU arithmetic correction — see commit 35ddbfa]
```

## Next steps (Day 3)

Priority order:

1. **Write `bpf/tc_ingress_eth0.bpf.c`** — counts ICMP PTBs arriving at the
   underlay interface before netfilter. This is the missing piece for suppression
   detection. Load with clang + bpftool on a Lima VM.

2. **Write `bpf/tc_egress_vxlan0.bpf.c`** — reads inner IP packet size and
   destination IP before VXLAN encapsulation. Reports to BPF map.

3. **Get bpftrace working** on Lima VM (Ubuntu 24.04 LTS): run
   `spikes/bpftrace/ip_do_fragment.bt` during large traffic and capture
   `outer_ip_len`, `dev_mtu`, `ip_excess` values.

4. **Test inject_ptb.py with TC ingress active** to verify the suppression
   detection signal: TC ingress count > 0 AND icmp_rcv count == 0.
