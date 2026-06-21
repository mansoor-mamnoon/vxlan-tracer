# Show HN draft

**Draft — do not post without approval.**

---

**Title:** Show HN: vxlan-tracer – eBPF tool to diagnose VXLAN MTU blackholes in Kubernetes

**URL:** https://github.com/mansoor-mamnoon/vxlan-tracer

---

**Body:**

Small eBPF diagnostic for a specific frustrating problem: Kubernetes clusters where ping works, small requests work, but large transfers (kubectl cp, big HTTP responses, file downloads) silently hang or stall after a few kilobytes.

One common root cause is VXLAN MTU misconfiguration. VXLAN adds 50 bytes of overhead per packet; if the overlay MTU isn't reduced to account for that, oversized outer packets get either fragmented (fragmented IP packets may be dropped or mishandled depending on the network path) or trigger ICMP "fragmentation needed" (PTB) messages that are suppressed by firewalls or eBPF policies before they can reach the pod.

vxlan-tracer attaches TC sched_cls hooks on the underlay ingress path (fires before netfilter) and on the VXLAN overlay egress (fires before VXLAN encapsulation), plus kprobes on `ip_do_fragment` and `icmp_rcv`. The counter comparison across these hooks produces one of six verdicts:

- `VXLAN_FRAGMENTATION_OBSERVED` — ip_do_fragment fired with corroborating TC egress signal; consistent with VXLAN-triggered fragmentation
- `PTB_SUPPRESSED` — PTBs observed at TC ingress (before netfilter) but absent at `icmp_rcv` (after netfilter); consistent with firewall/policy suppression
- `PTB_DELIVERED` — PTBs observed at TC ingress and confirmed at `icmp_rcv`
- `VXLAN_MTU_RISK` — oversized inner packets observed at TC egress with no fragmentation signal; consistent with MTU risk (note: may be a GSO super-packet false positive)
- `VXLAN_MTU_MISCONFIGURATION` — overlay MTU > underlay MTU − 50 bytes; static configuration risk, no active events required
- `NO_ISSUE_OBSERVED` — no relevant signal in this observation window

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
