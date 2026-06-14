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

## Hooks confirmed by architecture analysis (not yet tested on kernel)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| TC egress vxlan0 fires before VXLAN encap | Kernel source analysis | High |
| ip_do_fragment fires on DF=0 oversized outer | Kernel source analysis | High |
| TC ingress eth0 fires before netfilter | Kernel documentation | High |
| icmp_rcv fires after netfilter INPUT | Kernel documentation | High |
| ip_do_fragment symbol in /proc/kallsyms on 5.15 | Not verified (macOS dev env) | Unknown |
| bpftrace can read skb->dev->name in kprobe | Not verified | Unknown |
| fentry/icmp_rcv requires BTF available | Known requirement; /sys/kernel/btf/vmlinux must exist | Assumed |

## Next verification step

Run on a Linux 5.15 host:
```sh
grep ip_do_fragment /proc/kallsyms
ls /sys/kernel/btf/vmlinux
sudo bpftrace spikes/bpftrace/ip_do_fragment.bt
```
Record results in evidence/test-results.md.
