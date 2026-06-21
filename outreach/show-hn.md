# Show HN draft

**Draft — do not post without approval.**

---

**Title:** Show HN: vxlan-tracer – eBPF tool to diagnose VXLAN MTU blackholes in Kubernetes

**URL:** https://github.com/mansoor-mamnoon/vxlan-tracer

---

**Body:**

Small eBPF diagnostic for a specific frustrating problem: Kubernetes clusters where ping works, small requests work, but large transfers (kubectl cp, big HTTP responses, file downloads) silently hang or stall after a few kilobytes.

The root cause is usually VXLAN MTU misconfiguration. VXLAN adds 50 bytes of overhead per packet; if the overlay MTU isn't reduced to account for that, oversized outer packets get either fragmented (and then silently dropped by cloud fabric) or trigger ICMP "fragmentation needed" (PTB) messages that are suppressed by firewalls or eBPF policies before they can reach the pod.

vxlan-tracer attaches TC sched_cls hooks on the underlay ingress path (fires before netfilter) and on the VXLAN overlay egress (fires before encapsulation), plus kprobes on `ip_do_fragment` and `icmp_rcv`. The counter comparison across these hooks produces one of five verdicts:

- `VXLAN_FRAGMENTATION_OBSERVED` — fragmentation is actively occurring (corroborated by TC egress seeing oversized outer packets)
- `PTB_SUPPRESSED` — PTBs arrived at the NIC but were dropped before reaching `icmp_rcv`
- `PTB_DELIVERED` — PTBs are reaching the kernel's ICMP handler
- `VXLAN_MTU_MISCONFIGURATION` — static risk detected (overlay MTU > underlay MTU − 50), no active events needed
- `NO_ISSUE_OBSERVED` — nothing detected in the window

New: `vxlan-tracer interfaces` (no root required) enumerates VXLAN interfaces on the host with their VNI, port, MTU, and inferred underlay — so you don't have to guess interface names.

**Status:** Experimental prerelease. Validated in a controlled netns lab on 4 kernels (5.15 through 6.10, aarch64 and x86_64). Not yet tested against a real CNI cluster. If you run it on a staging node, the result — any result, including "no issue observed" — is useful to share back.

The main limitation is that `ip_do_fragment` is a global kernel function, so the fragmentation counter includes all IP fragmentation on the host, not just VXLAN. The TC egress corroboration signal reduces false positives but doesn't eliminate them.

amd64 and arm64 Linux binaries: https://github.com/mansoor-mamnoon/vxlan-tracer/releases/tag/v0.1.0-rc1

MIT licensed.

---

**Notes:**
- HN audience skews infra/SRE; the technical detail level is appropriate
- Lead with the symptom (silent stall), not the tool
- Be explicit about what's not validated to avoid the "it's not production ready" objection in comments
- Don't use "production-ready" language anywhere
