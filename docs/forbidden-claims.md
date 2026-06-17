# Forbidden Claims

This file documents claims that vxlan-tracer must never make — in the README,
documentation, commit messages, demo scripts, resume bullets, or any public
communication about the project.

Each entry explains why the claim is wrong or unverifiable.

---

## 1. "XDP-powered" / "XDP egress" / "dual XDP on vxlan0 + eth0"

**Why forbidden:** XDP is an ingress-only hook. It fires after NIC DMA on the
receive path. There is no XDP egress hook. `XDP_TX` retransmits the current
received packet back out — it is not an observation hook for outgoing traffic.
vxlan-tracer uses TC egress (cls_bpf on clsact qdisc) for all outgoing packet
observation. Claiming XDP egress in a Cloudflare or Datadog interview is an
immediate technical disqualifier.

---

## 2. "Inner 5-tuple extracted from ICMP PTB"

**Why forbidden:** ICMP Type 3 Code 4 (fragmentation-needed) contains:
- 8 bytes ICMP header (type, code, checksum, unused, next_hop_mtu)
- 20 bytes of the original outer IP header
- 8 bytes of the original outer UDP header

The inner IP header and inner TCP/UDP headers are NOT present. The inner source
port, destination port, and inner IP addresses cannot be read from a PTB.
Correlation from PTB to inner flows is at VTEP IP granularity only.

---

## 3. "Zero traffic disruption"

**Why forbidden:** TC egress BPF on vxlan0 runs on the hot path — every packet
sent across the overlay executes the BPF program. This adds CPU overhead (on
modern hardware, roughly 50–200ns per packet). Overhead is not zero. Never
claim zero overhead without measuring it.

---

## 4. "Production-validated" / "tested at scale" / "deployed at [company]"

**Why forbidden:** The tool has been tested only in isolated Linux network
namespace environments. No production cluster has run it. No scale measurement
has been taken. Do not fabricate production validation.

---

## 5. "Detects all VXLAN blackholes"

**Why forbidden:** vxlan-tracer detects the specific case where oversized outer
packets are fragmented or dropped on the local host's transmit path, and where
ICMP PTBs are suppressed by local firewall rules. It does not detect:
- Mid-path hardware blackholes where the undersized MTU is at a remote router
- Asymmetric routing MTU mismatches
- IPv6 inner or outer paths (not implemented)
- Non-VXLAN tunnel types (Geneve, GRE, WireGuard, IPIP)

---

## 6. "First ever" / "nobody has done this before"

**Why forbidden:** This claim cannot be proven and is almost certainly false.
pwru (Cilium), dropwatch, bpftrace community scripts, and various internal
tools at network equipment vendors all cover overlapping problem spaces.

---

## 7. "Zero configuration"

**Why forbidden:** The tool requires:
- `--overlay` and `--underlay` interface name arguments
- `CAP_BPF` and `CAP_NET_ADMIN` capabilities (or root)
- Linux kernel 5.15+
- `ip_do_fragment` symbol present in `/proc/kallsyms`

None of these are zero-config.

---

## 8. "tcpdump cannot see suppressed PTBs"

**Why forbidden (and the correct nuanced claim):**
tcpdump via AF_PACKET (libpcap's raw socket) fires before netfilter on ingress,
so it CAN see ICMP PTBs that iptables subsequently drops. The correct claim is:

> tcpdump can show that PTBs arrive at the NIC, but it cannot measure whether
> the kernel's `icmp_rcv` function was subsequently invoked. vxlan-tracer
> provides both a pre-netfilter PTB count (TC ingress) and a post-netfilter PTB
> count (icmp_rcv kprobe), and the delta between them is the suppression signal
> that a single tcpdump session cannot produce.

---

## 9. MTTR or performance numbers not measured

**Why forbidden:** Do not state "reduced diagnosis time from X hours to Y
seconds" without a real measurement and a real comparison baseline.

---

## 10. "Supports Geneve, GRE, WireGuard, IPIP"

**Why forbidden:** These tunnel types have different header structures and
different kernel code paths. None of them have been tested or implemented.
vxlan-tracer is explicitly VXLAN-only (UDP port 4789, VNI-based).

---

## 11. "XDP-only"

**Why forbidden:** Same as claim 1, additionally: the tool is not XDP-anything.

---

## 12. Fake benchmark numbers or fake test output

**Why forbidden:** If a test was not run, do not write its output. If a tool
did not produce a measurement, do not invent one. Evidence files must contain
only actual command output from actual runs.

---

## 13. "All fragmentation events are VXLAN-caused"

**Why forbidden:** `ip_do_fragment` is a global kernel function. It fires for
ALL outgoing IP fragmentation on the host, not only VXLAN outer packets.
The kprobe counter (`frag_events_total`) therefore counts all fragmentation.
On a busy multi-purpose host, this counter will include non-VXLAN fragmentation.

The verdict message must always include the global-scope disclaimer. The
corroborated verdict (both ip_do_fragment fires AND TC egress sees oversized
VXLAN packets) is stronger but still not definitive proof of VXLAN causation.

Forbidden phrases:
- "all frag events are VXLAN-caused"
- "ip_do_fragment only fires for VXLAN"
- "frag_events_total counts only VXLAN fragmentation"

---

## 14. "Packet loss confirmed"

**Why forbidden:** In a local lab environment, fragmented UDP packets
reassemble at the receiver. Fragmentation does not confirm packet loss.
In cloud fabric (AWS, GCP, Azure VPC), fragmented VXLAN UDP is commonly
silently dropped — but this tool runs on the local host and cannot observe
remote drops.

Do not claim packet loss from `frag_events_total > 0` alone.

---

## 15. "Idempotent across all kernel versions"

**Why forbidden:** The idempotent TC attach (`FilterList+FilterDel`) and map
clearing (`ClearPinned`) have been tested only on kernel 6.10.14-linuxkit.
`FilterList` behavior, ARRAY map `UpdateAny` semantics, and HASH map iteration
during flush are all kernel-implementation details. Claim only: "tested on
6.10.14-linuxkit aarch64."
