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
| TC egress vxlan0 fires before VXLAN encap | Kernel source analysis | High (unrun) |
| TC ingress eth0 fires before netfilter | Kernel documentation | High (unrun) |
| icmp_rcv fires after netfilter INPUT | Kernel documentation | High (unrun) |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Next verification step (Day 3)

1. Lima VM with bpftrace 0.16+:
   - Run `spikes/bpftrace/ip_do_fragment.bt` during large traffic
   - Confirm `outer_ip_len`, `dev_mtu`, `ip_excess` field values from skb
2. Implement `bpf/tc_ingress_eth0.bpf.c` and attach to underlay interface
3. Test inject_ptb.py with TC ingress BPF active; verify suppression signal
