# evidence/hook-findings.md

Documents the hook placement investigation: what was tested, what was confirmed,
what remains unverified, and any corrections made to the original architecture.

## Correction 1: XDP egress does not exist

**Original claim:** "dual XDP on vxlan0 + eth0"
**Correct architecture:** TC egress on vxlan0; no XDP on egress path
**Reason:** XDP fires on the ingress (receive) path only, after NIC DMA. There
is no XDP egress hook. `XDP_TX` retransmits the current received packet back;
it is not an observation point for outgoing traffic.
**Status:** Corrected in docs/architecture.md and docs/hook-model.md.
**Source:** Kernel documentation + review of kernel/bpf/net code path.

## Correction 2: TC egress on eth0 misses DF=1 drops

**Original assumption:** TC egress on eth0 could observe oversized packet drops
**Correct behavior:** For DF=1 packets, the drop happens inside
`ip_finish_output2` before control returns to TC egress. TC egress fires on the
path to the NIC, after the drop decision has already been made. For DF=1
oversized packets, TC egress on eth0 sees no traffic at all.
**Implication:** TC egress on eth0 is only useful in DF=0 configurations for
confirming outer frame sizes. Marked optional/debug.
**Status:** Documented in docs/hook-model.md.

## Correction 3: DF=0 is the Linux VXLAN default

**Original assumption:** ICMP PTB would be generated for oversized outer packets
**Correct behavior:** Linux VXLAN defaults to DF=0 on the outer IP header.
Oversized outer packets are fragmented by `ip_do_fragment`, not dropped. No
ICMP PTB is generated. The ICMP PTB path only fires when `df set` is configured.
**Implication:** `ip_do_fragment` kprobe MUST be in V0. Without it, the tool
produces zero output on default Flannel/Calico VXLAN deployments.
**Status:** ip_do_fragment kprobe included in V0 scope (docs/roadmap.md).

## Correction 4: ICMP PTB does not contain inner 5-tuple

**Original assumption:** inner flow could be identified from ICMP PTB
**Correct behavior:** ICMP PTB payload contains:
  - 8 bytes ICMP header
  - 20 bytes embedded original outer IP header
  - 8 bytes embedded original outer UDP header (first 8 bytes = UDP header)
The inner IP header and inner TCP/UDP headers are NOT present.
**Implication:** Correlation from PTB to inner flows is at VTEP IP granularity
only. Output must say "active flows to vtep X" not "flow Y is affected."
**Status:** Documented in docs/architecture.md and docs/forbidden-claims.md.

## Correction 5: tcpdump AF_PACKET also fires before netfilter

**Original claim:** "tcpdump cannot see suppressed PTBs"
**Correct behavior:** tcpdump via AF_PACKET (libpcap raw socket) fires before
netfilter on ingress and CAN see incoming ICMP PTBs that iptables subsequently
drops.
**Correct differentiation:** The unique value of vxlan-tracer's TC ingress +
icmp_rcv pair is the COUNT COMPARISON — tcpdump shows PTBs arrive but cannot
measure whether icmp_rcv was subsequently invoked. vxlan-tracer provides both
numbers simultaneously.
**Status:** Documented in docs/forbidden-claims.md, claim #8.

## Day 2 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 1: ip_do_fragment IS a T symbol and fires as expected

```
ffff800080ff71d8 T ip_do_fragment
```

Raw ftrace kprobe confirmed: 20 ip_do_fragment events for 10 large pings.
0 events for small pings. The hook is reliable and non-inlined on this kernel.

### Finding 2: icmp_send is NOT a T symbol on kernel 6.10.14

icmp_send does not appear as a T symbol in /proc/kallsyms. Exists only as:
```
__traceiter_icmp_send  T
__probestub_icmp_send  T
__bpf_trace_icmp_send  t
```
Use `tracepoint:net:icmp_send` instead of `kprobe:icmp_send` on this kernel.
(tracepoint provides type+code but not next_hop_mtu — see icmp_send.bt comments)

### Finding 3: BTF is present on linuxkit

`/sys/kernel/btf/vmlinux` exists (6.2 MB). fentry programs are supported.

### Finding 4: locally-generated PTBs bypass netfilter INPUT

For the DF=1 scenario (kernel generating PTBs for its own packets), the ICMP
PTBs do not traverse the INPUT chain. iptables DROP rule shows 0 counter hits.
The suppression detection is designed for externally-arriving PTBs (cloud fabric).

### Finding 5: kernel 6.10+ enforces correct vxlan0 MTU at creation time

`ip link set vxlan0 mtu 1500` returns `RTNETLINK answers: Invalid argument` when
underlay MTU is 1500. Kernel enforces max vxlan0 MTU = underlay - overhead.
Alternative topology: reduce underlay MTU after vxlan0 creation.

## Updated hook confidence table (post-Day 2)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings | **CONFIRMED** |
| ip_do_fragment not inlined on 6.10.14 | ftrace fires at +0x0 | **CONFIRMED** |
| icmp_send NOT a T symbol on 6.10.14 | /proc/kallsyms negative | **CONFIRMED** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| BTF vmlinux present on linuxkit | file size 6.2MB confirmed | **CONFIRMED** |
| TC egress vxlan0 fires before VXLAN encap | flow_state map populated; pkt_count=6 for 6 pings | **CONFIRMED** |
| TC ingress eth0 fires before netfilter | ptb_count=5 after 5 synthetic PTBs from ns2 | **CONFIRMED** |
| icmp_rcv fires after netfilter INPUT | Kernel documentation | High (unrun) |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Day 3 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 6: TC egress on vxlan0 fires before VXLAN encapsulation

flow_state map populated after 6 ICMP echo packets (3 small + 3 large):
- max_inner_ip_len=1428 for 1400-byte payload pings ✓
- max_outer_ip_len=1478 (= 1428 + 50) ✓
Confirms the hook fires on inner packets before the kernel adds VXLAN headers.

### Finding 7: TC ingress on veth1 fires before netfilter

ptb_ingress_counts[{192.168.100.2 → 192.168.100.1}].ptb_count = 5 after
5 synthetic PTBs injected from ns2. ptb_ingress_total = 5. All pass TC_ACT_OK.

### Finding 8: scapy ICMP type=3 'unused' vs 'nexthopmtu' field layout

In scapy, ICMP type=3 defines two separate ShortFields:
- `unused` (bytes 4-5): maps to icmph->un.frag.__unused
- `nexthopmtu` (bytes 6-7): maps to icmph->un.frag.mtu ← what BPF reads

inject_ptb.py was using `unused=MTU` instead of `nexthopmtu=MTU`, resulting in
next_hop_mtu=0 in the BPF map. Fixed in Commit 6.

### Finding 9: bpftool binary location on ubuntu:22.04 arm64

`linux-tools-5.15.0-181-generic` installs bpftool to two paths:
- `/usr/lib/linux-tools-5.15.0-181/bpftool` (actual binary)
- `/usr/lib/linux-tools/5.15.0-181-generic/bpftool` (symlink or alternate path)
`/usr/sbin/bpftool` is a wrapper that checks running kernel version and fails
on kernel 6.10.14. Use the versioned path directly.

## Day 4 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 10: icmp_rcv IS a T symbol and attaches via kprobe

```
ffff800080xxxxxx T icmp_rcv   (confirmed in /proc/kallsyms Day 2)
```

libbpf probe_attach.c attached kprobe/icmp_rcv via `bpf_program__attach_kprobe`.
bpftool confirmed: `182: kprobe name kprobe_icmp_rcv jited 192B map_ids 87`.

### Finding 11: icmp_rcv fires AFTER netfilter INPUT — proven by counter experiment

Without iptables DROP: ptb_ingress_total=5, icmp_rcv_total=5 (both match).
With iptables DROP on icmptype 3 code 4: ptb_ingress_total=5, icmp_rcv_total=0.
The DROP rule in netfilter INPUT prevents icmp_rcv from being called.

This proves the hook ordering:
```
TC ingress (pre-nf) → netfilter INPUT → icmp_rcv (post-nf)
```

### Finding 12: CO-RE not needed for icmp_rcv kprobe counting

kprobes.bpf.c does not access any struct fields from the skb. It only
increments a counter. No vmlinux.h, no CO-RE annotations. Compiled without
`-D__TARGET_ARCH_arm64` or BTF-related flags. This keeps the BPF simpler.

Caveat: in production, the kprobe would need to parse the skb to filter for
ICMP type=3 code=4 only, which DOES require CO-RE or a manual offset table.
Deferred to Day 5.

### Finding 13: stale vxlan0 MTU persists after underlay MTU reduction

Kernel 6.10.14 sets vxlan0 MTU = min(underlay-50, requested) at creation time.
If the underlay MTU is later reduced (e.g., via `ip link set veth1 mtu 1400`),
the vxlan0 MTU is NOT automatically updated. The stale MTU remains at 1450.

This is the real-world VXLAN blackhole condition: containers see overlay MTU
as 1450, send packets that become 1438-byte outer packets, which exceed the
1400-byte underlay MTU and are silently fragmented (DF=0) or dropped (DF=1).

### Finding 14: ip_do_fragment fires in both namespaces for each oversized ping

The ftrace kprobe on ip_do_fragment is global (all namespaces). For a 3-ping
test with ns1→ns2: 3 events from ns1 (send path) + 3 events from ns2 (reply
path) = 6 events total. Both sides have underlay MTU=1400 and both fragment.

## Updated hook confidence table (post-Day 4)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings | **CONFIRMED** |
| ip_do_fragment fires for stale-MTU scenario | ftrace kprobe: 6 events/3 pings | **CONFIRMED** |
| ip_do_fragment not inlined on 6.10.14 | ftrace fires at +0x0 | **CONFIRMED** |
| icmp_send NOT a T symbol on 6.10.14 | /proc/kallsyms negative | **CONFIRMED** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed Day 2 | **CONFIRMED** |
| icmp_rcv attaches via libbpf kprobe | bpftool: id 182, jited 192B | **CONFIRMED** |
| icmp_rcv fires AFTER netfilter INPUT | counter experiment: unsuppressed=5/5 | **CONFIRMED** |
| iptables DROP before icmp_rcv | counter experiment: suppressed=5/0, drops=5 | **CONFIRMED** |
| PTB suppression detectable: TC>0 + icmp_rcv==0 | both probes running; lab proven | **CONFIRMED** |
| BTF vmlinux present on linuxkit | file size 6.2MB confirmed | **CONFIRMED** |
| TC egress vxlan0 fires before VXLAN encap | flow_state populated; max_outer_ip_len=1478 | **CONFIRMED** |
| TC ingress eth0 fires before netfilter | ptb_count=5 after 5 synthetic PTBs | **CONFIRMED** |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |
| icmp_rcv kprobe filters type=3 code=4 only | Not implemented (counts all ICMP) | Not yet |
