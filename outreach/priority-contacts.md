# Priority Contacts — Ranked for First Outreach

**Selection criteria:** Scored out of 12 (symptom match × 3, recency × 3, likelihood of response × 3, unique environment value × 3).
**Purpose:** Research only. No contact without explicit approval.

---

## Scoring rubric

| Dimension | 3 pts | 2 pts | 1 pt |
|-----------|-------|-------|------|
| Symptom match | Exact: fragmentation/PTB suppression confirmed | Probable: large-packet stall, unresolved | Possible: MTU warning, peripheral |
| Recency | 2025–2026 | 2023–2024 | pre-2023 |
| Likelihood of response | Active issue, maintainer engaged, no fix merged | Issue still open, last comment <90d | Resolved or old |
| Environment value | Novel (new CNI, new kernel, cloud-specific) | Standard (common k3s/Calico setup) | Known (already in matrix) |

---

## PC01 — Cilium KubeVirt egress gateway fragmentation

- **issue:** https://github.com/cilium/cilium/issues/38828
- **score:** 12/12 (symptom 3, recency 3, response 3, environment 3)
- **why first:** April 2025, high-traffic Cilium issue, KubeVirt is a novel environment not in our matrix. Exact VXLAN_FRAGMENTATION_OBSERVED / PTB_SUPPRESSED scenario. Active Cilium maintainer engagement means any useful diagnostic tool shared here will get eyeballs.
- **approach:** Reply to the thread with a specific technical statement about vxlan-tracer's TC egress hook seeing exactly the cilium_vxlan egress path described in the issue. Offer to provide a binary or walk through running it.
- **key personalization:** Reference the specific cilium_vxlan interface name and the egress gateway path they described.

---

## PC02 — Calico: pod veth MTU randomly set to 1500 (January 2025)

- **issue:** https://github.com/projectcalico/calico/issues/9718
- **score:** 11/12 (symptom 3, recency 3, response 3, environment 2)
- **why second:** January 2025, intermittent nature (random probability of wrong MTU) means the reporter is likely still fighting this. VXLAN_MTU_MISCONFIGURATION is an exact match.
- **approach:** Reply noting that vxlan-tracer's interfaces subcommand enumerates VXLAN overlay interfaces and their MTU (does NOT scan pod veth interfaces — veth enumeration requires per-pod inspection that this tool does not do). The diagnostic verdict confirms whether active fragmentation is occurring at the VXLAN overlay level.
- **key personalization:** Reference the specific 1500 vs. 1400 boundary and the random probability nature of the bug.

---

## PC03 — Cilium drops ICMP FragmentationNeeded during eBPF masquerade (July 2024)

- **issue:** https://github.com/cilium/cilium/issues/33844
- **score:** 11/12 (symptom 3, recency 3, response 3, environment 2)
- **why third:** July 2024, active Cilium issue with SNAT + PTB interaction. PTB_SUPPRESSED verdict directly maps to this. vxlan-tracer can confirm whether the drop is at the TC layer (pre-SNAT) or at icmp_rcv (post-SNAT), which would narrow down the code path.
- **approach:** Offer to help triage by running vxlan-tracer to determine the drop layer. The TC/kprobe split gives information the Cilium team doesn't have from packet captures alone.
- **key personalization:** Reference the "Error while correcting L4 checksum" error message they reported and connect it to the SNAT+PTB interaction.

---

## PC04 — KubeVirt: slow VM throughput ~80 Mbit/s, unclear root cause (April 2024)

- **issue:** https://github.com/kubevirt/kubevirt/issues/11646
- **score:** 10/12 (symptom 2, recency 3, response 3, environment 2)
- **why fourth:** April 2024, still unresolved. The symptom (degraded throughput without a clear root cause) is exactly where a verdict-producing diagnostic tool adds the most value — it answers the "is this MTU?" question definitively. KubeVirt users are sophisticated.
- **approach:** Frame vxlan-tracer as a "rule-out" tool: run it to confirm or eliminate MTU blackhole as the cause of the 80 Mbit/s ceiling before investigating virtio or other paths.
- **key personalization:** Note that 80 Mbit/s is a specific throughput ceiling that often corresponds to a 1/10 path degradation from large-packet retransmits caused by PMTUD black holes.

---

## PC05 — Cilium + Tailscale: TLS handshake fails over stacked overlays (January 2026)

- **issue:** https://github.com/tailscale/tailscale/issues/18565
- **score:** 10/12 (symptom 3, recency 3, response 2, environment 2)
- **why fifth:** January 2026 (very recent), novel stacked-overlay scenario not in our matrix. vxlan-tracer's MTU misconfiguration check would give a clear verdict on the Cilium VXLAN layer, even if Tailscale adds additional complexity. High signal value for our matrix.
- **approach:** Acknowledge that Tailscale adds a layer beyond vxlan-tracer's primary scope, but the Cilium VXLAN MTU check is directly applicable — offer to help confirm whether the VXLAN portion of the stack is misconfigured.
- **key personalization:** Reference the specific MTU 1280 they mentioned and the TLS handshake EOF.

---

## PC06 — Calico eBPF + VXLAN + GRO: GSO size not adjusted (October 2025)

- **issue:** https://github.com/projectcalico/calico/issues/11160
- **score:** 10/12 (symptom 3, recency 3, response 2, environment 2)
- **why sixth:** October 2025, very recent. GRO + VXLAN interaction is technically complex — the Calico team is actively investigating. vxlan-tracer's TC egress hook observes exactly where GRO-recombined packets hit the MTU boundary.
- **approach:** Offer to run vxlan-tracer to confirm whether the TC egress hook is recording packets above the MTU (which would indicate GRO-recombined super-MTU packets arriving at the VXLAN encap path).
- **key personalization:** Reference the BPF_F_ADJ_ROOM_FIXED_GSO flag they mentioned and connect it to the TC hook observation point.

---

## PC07 — Cilium LoadBalancer: PTB messages loop on k8s host (August 2024)

- **issue:** https://github.com/cilium/cilium/issues/34380
- **score:** 10/12 (symptom 3, recency 3, response 2, environment 2)
- **why seventh:** August 2024, active issue with specific symptom (PTB looping). The TC → icmp_rcv split in vxlan-tracer directly answers the question of where the PTB is being lost.
- **approach:** Share the specific diagnostic approach: TC ingress count vs. icmp_rcv count. If TC > 0 and icmp_rcv = 0, the PTB is being dropped between the NIC and the kernel — PTB_SUPPRESSED verdict. This is the exact question their issue is asking.
- **key personalization:** Reference the "looping until TTL expires" behavior they described.

---

## PC08 — k3s/Flannel WireGuard wrong MTU on Azure (February 2022)

- **issue:** https://github.com/k3s-io/k3s/issues/5101
- **score:** 9/12 (symptom 3, recency 2, response 2, environment 2)
- **why eighth:** 2022 but still open. Azure + k3s is a high-volume target audience (Rancher/k3s is popular in edge and on-prem). The MTU misconfiguration is clear and vxlan-tracer's verdict would be immediate.
- **note:** WireGuard backend, not pure VXLAN — disclose this limitation clearly.
- **approach:** Note the WireGuard overlay distinction upfront; offer vxlan-tracer for diagnosing the Flannel VXLAN path if they also use VXLAN backend, and note that the MTU arithmetic is identical.
- **key personalization:** Reference the specific 1420 vs. 1350 MTU discrepancy on Azure that was reported.

---

## PC09 — Calico: NodePort TCP payload > 65KB hangs 60s on VMware (December 2023)

- **issue:** https://github.com/projectcalico/calico/issues/8349
- **score:** 9/12 (symptom 3, recency 2, response 2, environment 2)
- **why ninth:** December 2023, VMware is a unique and underserved environment for VXLAN diagnostics. The 60-second hang on large payloads is a textbook PMTUD black hole symptom with a clear vxlan-tracer mapping.
- **approach:** Connect the 60-second delay explicitly to the TCP retransmit timeout — this is the signal that PMTUD is broken, not a random slowdown. Offer vxlan-tracer as a 30-second test.
- **key personalization:** Reference the specific 65KB threshold and the VMware + Calico eBPF combination.

---

## PC10 — Cilium frag-needed blocked despite AllowICMPFragNeeded (June 2023)

- **issue:** https://github.com/cilium/cilium/issues/26193
- **score:** 9/12 (symptom 3, recency 2, response 2, environment 2)
- **why tenth:** June 2023, Cilium policy + PTB suppression interaction. The flag is supposed to allow PTBs but doesn't. vxlan-tracer can determine whether the block is at the TC hook (before the BPF policy evaluates the packet) or in the kprobe (post-policy).
- **approach:** Offer a specific diagnostic question: "Does vxlan-tracer show PTBs at TC ingress with zero at icmp_rcv? That would mean the drop is happening inside the BPF policy stack, not at the kernel level — and would narrow down which hook is responsible."
- **key personalization:** Reference the AllowICMPFragNeeded flag they mentioned.

---

## PC11 — Calico: wrong source IP in ICMP MTU-too-big on multi-NIC host

- **issue:** https://github.com/projectcalico/calico/issues/4439
- **score:** 9/12 (symptom 3, recency 1, response 3, environment 2)
- **why eleventh:** Multi-NIC diagnostic value is unique. The symptom (PTB generated but misdirected) is a less common scenario that vxlan-tracer's split measurement can isolate precisely.
- **approach:** Explain that vxlan-tracer's TC vs. icmp_rcv split is sensitive to which interface the PTB arrives on — if PTBs arrive on the wrong interface, the icmp_rcv kprobe would see zero on the correct interface while TC might show > 0 on a different NIC.
- **key personalization:** Reference the multi-NIC source IP misdirection specifically.

---

## PC12 — Cilium CFP: PMTUD generally broken (December 2025)

- **issue:** https://github.com/cilium/cilium/issues/43072
- **score:** 8/12 (symptom 2, recency 3, response 2, environment 1)
- **why twelfth:** High-visibility Cilium CFP thread. This is a design discussion, not a bug report, so the engagement is different — but being referenced here could lead to maintainer relationships.
- **approach:** Post a short, technical comment linking vxlan-tracer as a diagnostic complement. Don't claim it solves the design problem; frame it as "while the long-term fix is designed, vxlan-tracer gives operators a way to diagnose individual nodes today."
- **key personalization:** Reference the specific CFP language about E/W and N/S path PMTUD being unreliable.

---

## PC13 — Flannel: docker0 MTU 1500, DinD builds hang

- **issue:** https://github.com/flannel-io/flannel/issues/1171
- **score:** 8/12 (symptom 3, recency 1, response 2, environment 2)
- **why thirteenth:** High-traffic issue frequently referenced by new users hitting docker0/flannel.1 MTU mismatch. The textbook nature of this scenario makes it a good showcase for vxlan-tracer's VXLAN_MTU_MISCONFIGURATION verdict.
- **approach:** Target a recent comment thread referencing this issue, not the original 2019 reporter. Frame as "if you're still hitting this, here's a tool that gives you a definitive verdict in 30 seconds."
- **key personalization:** Reference the docker0 (1500) vs. flannel.1 (1450) specific boundary.

---

## PC14 — KubeVirt: VM NIC doesn't know about VXLAN overhead, TCP timeouts

- **issue:** https://github.com/kubevirt/kubevirt/issues/987
- **score:** 7/12 (symptom 3, recency 1, response 2, environment 1)
- **why fourteenth:** KubeVirt is an important environment but this issue is older. Still, KubeVirt + VXLAN is a scenario that benefits from a verdict-producing tool.
- **approach:** Target recent comments on this thread rather than the original reporter. Offer vxlan-tracer as a way to confirm the tap interface MTU mismatch.
- **key personalization:** Reference the specific DHCP MTU option workaround they proposed.

---

## PC15 — Calico periodic vxlan.calico drops every 40-60 minutes

- **issue:** https://github.com/projectcalico/calico/issues/5696
- **score:** 7/12 (symptom 2, recency 2, response 2, environment 1)
- **why fifteenth:** The periodic drop pattern is interesting for vxlan-tracer — it suggests traffic-pattern-driven MTU boundary hits. Running vxlan-tracer during an affected window gives a clean answer.
- **approach:** Focus on the "run during an affected window" diagnostic angle. The 40-60 minute period suggests a workload pattern; vxlan-tracer's TC hook would catch the fragmentation burst if MTU is the cause.
- **key personalization:** Reference the specific 40-60 minute pattern and the transient nature of the drops.

---

## Summary table

| Rank | ID | Issue | Score | Primary verdict |
|------|-----|-------|-------|----------------|
| 1 | PC01 | Cilium/KubeVirt egress gateway | 12 | VXLAN_FRAGMENTATION_OBSERVED |
| 2 | PC02 | Calico random veth MTU 1500 | 11 | VXLAN_MTU_MISCONFIGURATION |
| 3 | PC03 | Cilium eBPF masquerade drops PTB | 11 | PTB_SUPPRESSED |
| 4 | PC04 | KubeVirt slow 80 Mbit/s | 10 | VXLAN_FRAGMENTATION_OBSERVED |
| 5 | PC05 | Cilium + Tailscale stacked MTU | 10 | VXLAN_MTU_MISCONFIGURATION |
| 6 | PC06 | Calico GRO + VXLAN GSO bug | 10 | VXLAN_FRAGMENTATION_OBSERVED |
| 7 | PC07 | Cilium LoadBalancer PTB loops | 10 | PTB_SUPPRESSED |
| 8 | PC08 | k3s WireGuard wrong MTU Azure | 9 | VXLAN_MTU_MISCONFIGURATION |
| 9 | PC09 | Calico NodePort 65KB hang VMware | 9 | PTB_SUPPRESSED |
| 10 | PC10 | Cilium AllowICMPFragNeeded ignored | 9 | PTB_SUPPRESSED |
| 11 | PC11 | Calico multi-NIC wrong PTB source IP | 9 | PTB_SUPPRESSED |
| 12 | PC12 | Cilium CFP: PMTUD broken | 8 | (design discussion) |
| 13 | PC13 | Flannel docker0 MTU 1500 DinD | 8 | VXLAN_MTU_MISCONFIGURATION |
| 14 | PC14 | KubeVirt VXLAN overhead TCP timeouts | 7 | VXLAN_MTU_MISCONFIGURATION |
| 15 | PC15 | Calico periodic vxlan.calico drops | 7 | VXLAN_FRAGMENTATION_OBSERVED |
