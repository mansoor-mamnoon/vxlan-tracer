# VXLAN MTU Blackhole — Lead List

**Research date:** 2026-06-20
**Purpose:** Engineers publicly reporting VXLAN/MTU fragmentation symptoms who
may benefit from vxlan-tracer as a diagnostic tool.
**Status:** Research only. No outreach without explicit approval.

---

## L001 — Cilium / KubeVirt egress gateway fragmentation

- **source_url:** https://github.com/cilium/cilium/issues/38828
- **date:** April 2025
- **project/community:** Cilium / KubeVirt
- **exact_symptom:** Inbound packets from the Cilium egress gateway exceeding (underlay MTU − VXLAN overhead) are dropped. HTTP responses entering cilium_vxlan are fragmented and never reach the destination VM.
- **environment:** KubeVirt VMs, Cilium VXLAN tunnel mode, egress gateway, Linux
- **vxlan_tracer_relevance:** Canonical VXLAN fragmentation blackhole; PTB_SUPPRESSED or VXLAN_FRAGMENTATION_OBSERVED directly describes this scenario.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** We built vxlan-tracer, an eBPF tool that attaches TC + kprobes to catch exactly this egress-gateway/VXLAN fragmentation blackhole — it can tell you whether PTB messages are being suppressed or delivered, which would narrow down where the drop is happening for your KubeVirt setup.
- **risks:** May have been partially addressed by a Cilium patch; confirm current status first.

---

## L002 — Cilium drops ICMP FragmentationNeeded during eBPF masquerade

- **source_url:** https://github.com/cilium/cilium/issues/33844
- **date:** July 2024
- **project/community:** Cilium
- **exact_symptom:** Cilium drops ICMP DestinationUnreachable "FragmentationNeeded" packets when eBPF masquerading is enabled. "Error while correcting L4 checksum" for the PTB packets. SNAT translation of PTB messages fails silently.
- **environment:** Cilium with eBPF masquerade, VXLAN tunnel mode
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — eBPF SNAT eating the fragmentation signal before it reaches the pod.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer attaches a kprobe on icmp_rcv and TC hooks to determine whether PTB messages are being dropped before reaching the pod — this could give you a definitive answer on where in the eBPF stack the FragmentationNeeded packets are getting lost.
- **risks:** May be a Cilium eBPF SNAT bug, not a misconfiguration — vxlan-tracer confirms suppression but doesn't fix it.

---

## L003 — Cilium LoadBalancer: PTB messages loop on k8s host instead of propagating

- **source_url:** https://github.com/cilium/cilium/issues/34380
- **date:** August 2024
- **project/community:** Cilium
- **exact_symptom:** Communication to LoadBalancer services fails when external clients are on a lower MTU. ICMP "fragmentation needed" messages loop on the Kubernetes host until TTL expires instead of being delivered to the pod.
- **environment:** Cilium VXLAN tunnel mode, LoadBalancer service, external clients
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — PTB looping on the node, never reaching the pod. vxlan-tracer's icmp_rcv kprobe confirms whether PTBs arrive at the TC layer vs. the kernel.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** Your symptom — PTB messages looping on the k8s host instead of reaching the pod — is exactly what vxlan-tracer's PTB_SUPPRESSED verdict catches via TC and kprobe hooks.
- **risks:** May involve cloud firewall rules; vxlan-tracer still useful for confirmation.

---

## L004 — Cilium drops ICMP frag-needed even when AllowICMPFragNeeded is set

- **source_url:** https://github.com/cilium/cilium/issues/26193
- **date:** June 2023
- **project/community:** Cilium
- **exact_symptom:** ICMP fragmentation-needed packets are blocked when a Cilium ingress policy is present, even when AllowICMPFragNeeded flag should permit them.
- **environment:** Cilium with eBPF, ingress network policy
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — policy-based suppression; vxlan-tracer determines whether drop is at TC hook (before policy) or deeper in kernel.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can pinpoint whether the fragmentation-needed block is at the TC hook (before BPF policy) or deeper, which would narrow down whether this is a policy ordering bug.
- **risks:** May have been fixed in a Cilium point release.

---

## L005 — Cilium drops out-of-order IP fragments (large UDP)

- **source_url:** https://github.com/cilium/cilium/issues/25709
- **date:** 2023
- **project/community:** Cilium
- **exact_symptom:** Large UDP packets that require fragmentation are dropped by the from-netdev BPF program. Out-of-order IP fragments not handled.
- **environment:** Cilium eBPF datapath, VXLAN, UDP
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — TC sched_cls attachment observes exactly where fragments are being dropped.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm from the TC layer whether fragmented UDP packets are exiting the VXLAN interface intact or being dropped before reassembly.
- **risks:** May be a known Cilium eBPF fragment tracking bug with a targeted fix.

---

## L006 — Cilium sets wrong MTU 1500 on veth interfaces in VXLAN mode

- **source_url:** https://github.com/cilium/cilium/issues/23711
- **date:** February 2023
- **project/community:** Cilium
- **exact_symptom:** Cilium sets MTU 1500 on veth interfaces in VXLAN tunnel mode instead of accounting for 50-byte overhead. Every packet over 1450 bytes is a blackhole candidate.
- **environment:** Cilium VXLAN tunnel mode, any Linux host
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — vxlan-tracer's misconfiguration check compares inner vs. outer MTU minus overhead and flags the mismatch directly.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** This is exactly the misconfiguration class that vxlan-tracer's VXLAN_MTU_MISCONFIGURATION verdict catches — it compares the inner interface MTU vs. (outer MTU − 50 bytes) and flags the mismatch.
- **risks:** May have been patched in Cilium 1.14+.

---

## L007 — Cilium PTB not delivered in ECMP (routed to wrong node)

- **source_url:** https://github.com/cilium/cilium/issues/19720
- **date:** May 2022
- **project/community:** Cilium
- **exact_symptom:** In ECMP scenarios, the PTB message is routed to a different k8s node than the one that sent the oversized packet. The originating node never receives the signal and keeps sending oversized packets.
- **environment:** Cilium, ECMP load balancing
- **vxlan_tracer_relevance:** PTB_SUPPRESSED (effectively) — vxlan-tracer's icmp_rcv kprobe confirms whether PTBs arrive at a node but are never forwarded to the originating pod.
- **confidence:** high
- **active:** yes (CFP remains open)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer tracks PTB delivery vs. suppression at the kernel kprobe level — in your ECMP scenario it would confirm whether PTB messages are arriving on the wrong node, which matches your routing asymmetry hypothesis.
- **risks:** vxlan-tracer confirms symptom but cannot fix ECMP routing asymmetry.

---

## L008 — Cilium node-to-node encryption + VXLAN causes connectivity loss

- **source_url:** https://github.com/cilium/cilium/issues/15756
- **date:** 2021 (referenced through 2023)
- **project/community:** Cilium
- **exact_symptom:** Enabling Cilium node-to-node encryption over VXLAN causes pods on different nodes to lose connectivity. Problem disappears when encryption is disabled. Packets near MTU are silently dropped.
- **environment:** Cilium VXLAN + WireGuard/IPsec encryption, multi-node cluster
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — encryption overhead on top of VXLAN overhead without MTU adjustment creates a double-overhead blackhole.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** The encryption + VXLAN double-overhead MTU blackhole is a class vxlan-tracer catches — it would show whether packets are being fragmented inside the VXLAN tunnel or dropped silently due to combined overhead exceeding the physical link MTU.
- **risks:** Encryption overhead varies by cipher.

---

## L009 — Cilium picks wrong MTU on multi-NIC host (uses 1460 instead of 1410)

- **source_url:** https://github.com/cilium/cilium/issues/14829
- **date:** February 2021 (referenced through 2023)
- **project/community:** Cilium
- **exact_symptom:** When host has multiple interfaces (ens4 at 1460, VXLAN at 1410), Cilium picks the wrong interface MTU for pod MTU. Large packets from pods are dropped.
- **environment:** Multi-NIC Linux host, Cilium VXLAN tunnel mode
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — vxlan-tracer detects pod MTU exceeding (outer MTU − VXLAN overhead) independently of which interface Cilium reports.
- **confidence:** medium
- **active:** yes (design issue, not fully resolved)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer has a check specifically for multi-interface MTU detection failures — it would confirm whether your pod MTU exceeds the safe threshold, independently of Cilium's self-reported values.
- **risks:** May have been fixed in newer Cilium.

---

## L010 — Cilium CFP: IP fragmentation and PMTUD generally broken

- **source_url:** https://github.com/cilium/cilium/issues/43072
- **date:** December 2025
- **project/community:** Cilium
- **exact_symptom:** CFP acknowledging "IP fragmentation and PMTUD is generally broken" in Cilium's E/W and N/S paths.
- **environment:** Cilium general; all encapsulation modes
- **vxlan_tracer_relevance:** Open design acknowledgment that vxlan-tracer's problem domain is real and unaddressed. Sharing as a diagnostic complement could get traction.
- **confidence:** medium
- **active:** yes (active CFP)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer is a purpose-built eBPF diagnostic for exactly the PMTUD/fragmentation blackhole — attaches to TC and kprobes to give a deterministic verdict. Might be worth linking as a diagnostic complement to whatever the long-term fix looks like.
- **risks:** Design proposal thread; engagement may be lower.

---

## L011 — Cilium 1.15.5 on Azure reduces eth0 MTU to 1400, causing TCP timeouts

- **source_url:** https://github.com/cilium/cilium/issues/33258
- **date:** 2024
- **project/community:** Cilium
- **exact_symptom:** After upgrading to Cilium 1.15.5 on Azure, eth0 MTU drops to 1400, causing TCP timeouts. Manually raising MTU from 1400 to 1450 resolves the issue.
- **environment:** Azure, Cilium 1.15.5, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — Azure underlay MTU 1400 minus VXLAN overhead leaves only 1350 bytes.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm whether the 1400/1450 boundary is producing fragmentation or PTB suppression in your Azure setup — it takes 30 seconds to run and gives a deterministic verdict.
- **risks:** Azure-specific MTU setting issue; root cause partially known.

---

## L012 — Cilium 1.17 upgrade changes Multus interface MTU to 1450

- **source_url:** https://github.com/cilium/cilium/issues/37824
- **date:** February 2025
- **project/community:** Cilium / Multus
- **exact_symptom:** Upgrading Cilium from 1.16.7 to 1.17.0+ changes the MTU of Multus-attached interfaces to 1450, breaking connectivity on secondary interfaces.
- **environment:** Cilium 1.17+, Multus CNI, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — wrong MTU on secondary interfaces post-upgrade.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can attach to the affected Multus interfaces to verify whether the 1450 MTU is causing VXLAN fragmentation or PTB suppression on cross-node traffic.
- **risks:** Known regression; vxlan-tracer is diagnostic, not a fix.

---

## L013 — Cilium pods don't respect per-route MTU (jumbo frames)

- **source_url:** https://github.com/cilium/cilium/issues/41478
- **date:** September 2025
- **project/community:** Cilium
- **exact_symptom:** Cilium pods don't respect per-route MTU on the host. Pods operate at wrong effective MTU, causing unnecessary fragmentation on jumbo-frame paths.
- **environment:** Cilium, jumbo frames, per-route MTU, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — vxlan-tracer validates the actual effective MTU at the TC layer.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can independently measure the effective MTU at the TC layer, which would confirm whether the per-route MTU is actually being honored during encapsulation.
- **risks:** Jumbo frame environments may need additional context.

---

## L014 — Flannel: docker0 inherits MTU 1500, DinD builds hang

- **source_url:** https://github.com/flannel-io/flannel/issues/1171
- **date:** 2019 (actively referenced through 2023)
- **project/community:** Flannel
- **exact_symptom:** Docker-in-docker builds hang because large package downloads get stuck in a PMTUD black hole. Flannel vxlan eth0 has MTU 1450, but docker0 inherits MTU 1500.
- **environment:** Flannel VXLAN, Docker-in-Docker, any Linux host
- **vxlan_tracer_relevance:** PTB_SUPPRESSED / VXLAN_MTU_MISCONFIGURATION — docker0 1500 MTU means any cross-VXLAN packet above 1450 bytes is dropped and the PTB is never returned.
- **confidence:** high
- **active:** yes (still referenced by new reporters)
- **contact_method:** issue reply
- **suggested_opening:** This is the textbook VXLAN PMTUD black hole — vxlan-tracer would tell you definitively whether PTBs are being suppressed or if the MTU mismatch between docker0 (1500) and flannel.1 (1450) is the root cause.
- **risks:** Old issue; reporter may no longer be active, but new commenters hit the same problem.

---

## L015 — Flannel on AWS: packet fragmentation due to MTU variations

- **source_url:** https://github.com/flannel-io/flannel/issues/627
- **date:** 2016 (canonical reference, still cited)
- **project/community:** Flannel / AWS
- **exact_symptom:** VXLAN performance degrades on AWS on non-network-optimized instances. Packets fragmented due to MTU mismatch between flannel VXLAN (1450) and AWS VPC underlay MTU variations.
- **environment:** AWS, Flannel VXLAN, non-network-optimized EC2 instances
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — fragmentation at the AWS underlay boundary.
- **confidence:** medium
- **active:** unknown (old issue; ongoing AWS problem class)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm whether the AWS VXLAN fragmentation is actively occurring and whether PTB signals are being suppressed, which would narrow down the fix.
- **risks:** Old issue; new reporters on the same thread are better targets.

---

## L016 — Flannel wrong DOCKER_OPT_MTU on AWS (wrong interface detected)

- **source_url:** https://github.com/flannel-io/flannel/issues/841
- **date:** 2017 (referenced through 2022)
- **project/community:** Flannel / AWS
- **exact_symptom:** Flannel doesn't detect host interface MTU correctly on AWS; sets DOCKER_OPT_MTU based on wrong interface. Results in oversized VXLAN-encapsulated packets.
- **environment:** AWS, Flannel VXLAN v0.8+, EC2 instances
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — wrong MTU detection means pods operate at 1500 while VXLAN path supports only 1450.
- **confidence:** medium
- **active:** unknown
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can independently verify the effective VXLAN MTU at the TC layer, bypassing whatever flannel reports.
- **risks:** Old issue; may have been fixed.

---

## L017 — k3s/Flannel WireGuard backend: wrong MTU on Azure (1420 instead of 1350)

- **source_url:** https://github.com/k3s-io/k3s/issues/5101
- **date:** February 2022
- **project/community:** k3s / Flannel WireGuard
- **exact_symptom:** On Azure with flannel-backend=wireguard, MTU is auto-set to 1420 instead of correct 1350. Causes large amounts of fragmentation.
- **environment:** k3s, Flannel WireGuard backend, Azure, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION (analogous for WireGuard overlay) — vxlan-tracer's misconfiguration detection logic applies directly.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer's MTU misconfiguration verdict would confirm whether the 1420 MTU setting is causing fragmentation on your WireGuard path — it runs directly on the data plane rather than relying on flanneld's self-reported values.
- **risks:** WireGuard backend, not VXLAN — note the scope difference in any outreach.

---

## L018 — Calico: pod veth MTU randomly set to 1500 instead of 1400

- **source_url:** https://github.com/projectcalico/calico/issues/9718
- **date:** January 2025
- **project/community:** Calico
- **exact_symptom:** When using Calico CNI, the MTU of the pod veth NIC is set to 1500 with random probability instead of correct 1400 (eth0 MTU 1450 − 50 byte VXLAN overhead). Causes intermittent large packet drops.
- **environment:** Calico VXLAN, Kubernetes, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — vxlan-tracer can run per-pod to check which pods have wrong MTU and whether those produce fragmentation events.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can run per-pod to check which pods have veth MTU 1500 vs. 1400 and whether those with 1500 are producing fragmented or dropped traffic — quick pass/fail diagnostic.
- **risks:** Race condition in Calico's CNI plugin; vxlan-tracer useful for triaging, not preventing.

---

## L019 — Calico multi-NIC: wrong source IP in ICMP MTU-too-big replies

- **source_url:** https://github.com/projectcalico/calico/issues/4439
- **date:** 2021
- **project/community:** Calico
- **exact_symptom:** In multi-NIC Calico VXLAN scenario, source IP in ICMP MTU-too-big replies is incorrect, causing replies to be routed to wrong interface/node and never reaching the TCP sender.
- **environment:** Calico VXLAN, multi-NIC Linux host, Kubernetes
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — PTB generated but misdirected. vxlan-tracer's icmp_rcv kprobe confirms whether PTBs arrive on the correct interface.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer's icmp_rcv kprobe attachment would confirm whether PTB messages are arriving on the correct interface or being misdirected in your multi-NIC setup.
- **risks:** Multi-NIC routing complexity; output needs careful interpretation.

---

## L020 — Calico: periodic packet drops on vxlan.calico every 40-60 minutes

- **source_url:** https://github.com/projectcalico/calico/issues/5696
- **date:** March 2022
- **project/community:** Calico
- **exact_symptom:** Every 40-60 minutes, packet drops occur on vxlan.calico, causing sporadic TCP connection resets. Drops are transient and periodic.
- **environment:** Calico VXLAN, bare-metal Kubernetes, Linux
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — periodic drops align with fragmentation black hole events when traffic patterns temporarily hit MTU limits.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** The 40-60 minute periodic pattern on vxlan.calico is consistent with workload-driven MTU blackhole events — vxlan-tracer can be run during an affected window to determine whether fragmentation is the trigger.
- **risks:** Root cause may be ARP/FDB expiry rather than MTU.

---

## L021 — Calico multi-NIC: VXLAN decap doesn't occur, wrong interface selected

- **source_url:** https://github.com/projectcalico/calico/issues/6051
- **date:** May 2022
- **project/community:** Calico
- **exact_symptom:** When host has multiple network interfaces, VXLAN decapsulation doesn't occur because Calico listens on wrong interface. VXLAN header present in traffic destined for containers, causing endless TCP retransmission.
- **environment:** Calico VXLAN, multi-NIC host, Kubernetes, Linux
- **vxlan_tracer_relevance:** TC sched_cls attachment can detect whether VXLAN packets are being decapsulated on the correct interface or passing through undecapsulated.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer's TC sched_cls attachment can detect whether VXLAN packets are being decapsulated on the correct interface or passing through undecapsulated — this would confirm whether multi-NIC routing is the root cause.
- **risks:** Root cause is Calico's VTEP interface selection bug; vxlan-tracer diagnosis may be partial.

---

## L022 — Calico: NodePort requests with large TCP payload hang on VMware

- **source_url:** https://github.com/projectcalico/calico/issues/8349
- **date:** December 2023
- **project/community:** Calico
- **exact_symptom:** NodePort requests with TCP payload larger than 65KB hang for 60+ seconds when using Calico eBPF dataplane with VXLAN on VMware.
- **environment:** Calico v3.25.0, eBPF dataplane, VXLAN, VMware, Kubernetes
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — 65KB+ payloads exceeding MTU triggering fragmentation or PTB suppression. 60-second delay is the TCP retransmit timeout — sender waiting for PTB that never arrives.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** The 60-second delay for large payloads is a classic PMTUD black hole symptom — the sender exhausts retransmit timeout waiting for a PTB that never arrives. vxlan-tracer would give you a definitive verdict on whether PTBs are being suppressed on your VMware VXLAN path.
- **risks:** VMware vSphere networking may add variables; ensure kernel 5.15+.

---

## L023 — Calico eBPF + VXLAN + GRO: GSO size not adjusted, drops super-MTU packets

- **source_url:** https://github.com/projectcalico/calico/issues/11160
- **date:** October 2025
- **project/community:** Calico
- **exact_symptom:** Calico eBPF + VXLAN with GRO enabled: GRO recombination creates super-MTU packets that exceed VXLAN encap MTU after re-encapsulation. BPF_F_ADJ_ROOM_FIXED_GSO prevents GSO size adjustment.
- **environment:** Calico eBPF + VXLAN, GRO enabled, Kubernetes, Linux 5.15+
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — TC egress hook sees oversized GRO-recombined packets at the VXLAN egress path.
- **confidence:** high
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer's TC egress hook would confirm whether GRO-recombined packets are hitting the VXLAN MTU boundary and being dropped vs. fragmented — this would validate whether the BPF_F_ADJ_ROOM_FIXED_GSO interaction is the root cause.
- **risks:** Requires a Calico eBPF patch to fix; vxlan-tracer is confirmatory.

---

## L024 — Calico IPIP/VXLAN: no PTB generated for host-networked pods

- **source_url:** https://github.com/projectcalico/calico/issues/1709
- **date:** 2019 (extensively referenced through 2023)
- **project/community:** Calico
- **exact_symptom:** When using Calico CNI with host-networking pods, Linux does not generate an ICMP "Packet too big" message for oversized packets. Packets over 1460 bytes silently dropped with no feedback.
- **environment:** Calico IPIP or VXLAN, host-network pods, Kubernetes, Linux
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — confirmed suppression of PTB generation for host-networked pods. vxlan-tracer's icmp_rcv kprobe confirms no PTB generated at host layer.
- **confidence:** high
- **active:** yes (frequently referenced in 2022-2024 discussions)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer was designed to catch exactly this — the silent drop without PTB for host-networked pods. It attaches kprobes to icmp_rcv to confirm whether PTBs are being generated at all.
- **risks:** IPIP vs. VXLAN distinction — clarify which encap mode before using.

---

## L025 — Rancher: incorrect veth MTU on host causes large packet drops

- **source_url:** https://github.com/rancher/rancher/issues/10498
- **date:** 2019 (referenced through 2022)
- **project/community:** Rancher
- **exact_symptom:** Incorrect MTU on veth interfaces on the host causes packet drops for large packets. Packets too large for the overlay are dropped without PTB generation.
- **environment:** Rancher, VXLAN overlay, Linux, Kubernetes
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — wrong veth MTU causes large cross-VXLAN packets to be dropped silently.
- **confidence:** medium
- **active:** unknown
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can scan your veth interface MTU vs. outer VXLAN MTU to confirm whether the misconfiguration is the active root cause of your packet drops.
- **risks:** Rancher 1.x vs. 2.x difference; issue may be from EOL version.

---

## L026 — Rancher: linkMTUOverhead (50 bytes) hardcoded, not configurable

- **source_url:** https://github.com/rancher/rancher/issues/11438
- **date:** 2018 (referenced through 2023)
- **project/community:** Rancher
- **exact_symptom:** linkMTUOverhead value for VXLAN (50 bytes) is hardcoded and not configurable. Packet loss windows exactly 5 bytes smaller than overhead value — TCP stalls on payloads near MTU boundary.
- **environment:** Rancher, VXLAN network stack, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — vxlan-tracer measures actual VXLAN overhead at TC layer rather than trusting configured values.
- **confidence:** medium
- **active:** yes (referenced through 2023)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer measures actual VXLAN overhead at the TC layer rather than trusting configured values — it would confirm whether the hardcoded 50-byte overhead is correct for your environment.
- **risks:** Rancher configuration API limitation; vxlan-tracer is diagnostic only.

---

## L027 — Rancher Canal/Flannel: MTU set to 1500 instead of 1450

- **source_url:** https://github.com/rancher/rancher/issues/13984
- **date:** 2018 (referenced through 2022)
- **project/community:** Rancher / Canal / Flannel
- **exact_symptom:** Rancher Canal network provider sets MTU 1500 instead of 1450 (accounting for 50-byte VXLAN overhead). Intermittent TCP retransmission errors and poor performance on cross-node pod traffic.
- **environment:** Rancher, Canal (Calico + Flannel), VXLAN, Kubernetes
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — all large cross-node packets enter the fragmentation path.
- **confidence:** medium
- **active:** unknown
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm in 30 seconds whether the 1500 vs. 1450 MTU difference is actively causing fragmentation or PTB suppression on your Canal/VXLAN path.
- **risks:** Canal is deprecated in newer Rancher; issue may be moot.

---

## L028 — KubeVirt: VM NIC doesn't know about VXLAN overhead, TCP timeouts

- **source_url:** https://github.com/kubevirt/kubevirt/issues/987
- **date:** 2019 (problem class remains active through 2024)
- **project/community:** KubeVirt
- **exact_symptom:** MTU mismatch between KubeVirt VM's virtual NIC and underlying Kubernetes pod network (VXLAN overlay) causes TCP connection timeouts. Fix proposed: advertise correct MTU to VMs via DHCP option.
- **environment:** KubeVirt, any CNI with VXLAN overlay, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — VM's network stack is unaware of VXLAN overhead, sends full 1500-byte packets that are silently dropped.
- **confidence:** medium
- **active:** yes (problem class ongoing)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm whether the VXLAN MTU mismatch is actively dropping large packets at the tap interface level inside your KubeVirt setup.
- **risks:** DHCP-based MTU fix may have landed in newer KubeVirt.

---

## L029 — KubeVirt: slow VM network speed (~80 Mbit/s), unclear root cause

- **source_url:** https://github.com/kubevirt/kubevirt/issues/11646
- **date:** April 2024
- **project/community:** KubeVirt
- **exact_symptom:** Slow network speed (~80 Mbit/s) inside KubeVirt VMs on Multus and masquerade connections. No clear root cause identified.
- **environment:** KubeVirt, Multus, masquerade networking, Kubernetes, Linux
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED — degraded throughput is a common symptom of VXLAN fragmentation; fragmenting large packets increases CPU overhead and causes retransmits.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** Low VM throughput on VXLAN overlays is frequently caused by silent fragmentation — vxlan-tracer would tell you in under a minute whether fragmentation is occurring on your data path.
- **risks:** Slow speed may have other causes (QEMU virtio, TSO offload); vxlan-tracer rules in/out MTU as a factor.

---

## L030 — kubectl delete hangs during MTU/PMTU-related large packet loss

- **source_url:** https://github.com/kubernetes/kubectl/issues/1779
- **date:** 2022
- **project/community:** Kubernetes / kubectl
- **exact_symptom:** During a period of severe packet loss specifically affecting large packets, a kubectl delete command became unresponsive. Reporter explicitly diagnoses as MTU/PMTUD-related packet loss.
- **environment:** Kubernetes cluster, overlay networking (CNI unspecified), Linux
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — kubectl hangs because large API response packets can't traverse the overlay and PTB feedback is suppressed.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** The kubectl hang during large-packet loss periods is a classic PMTUD black hole symptom — vxlan-tracer would give you a definitive verdict on whether PTBs are being suppressed on your overlay.
- **risks:** CNI type unspecified; VXLAN not confirmed.

---

## L031 — Kubernetes on AWS: ELB blocks ICMP, PMTUD breaks silently

- **source_url:** https://github.com/kubernetes/kubernetes/issues/24254
- **date:** 2016 (problem class referenced through 2023)
- **project/community:** Kubernetes / AWS ELB
- **exact_symptom:** AWS ELB firewall rules don't include ICMP, so PTB messages from ELB to pod are blocked. PMTUD breaks silently between external clients and pods behind ELB.
- **environment:** Kubernetes on AWS, ELB, VXLAN/overlay CNI
- **vxlan_tracer_relevance:** PTB_SUPPRESSED — firewall-level PTB suppression. vxlan-tracer's icmp_rcv kprobe confirms whether no PTBs arrive at the pod from the ELB direction.
- **confidence:** medium
- **active:** yes (AWS ELB ICMP filtering is a persistent known issue)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm whether PTB messages are reaching your pods from the ELB direction — if icmp_rcv never fires for PTB packets, that confirms the AWS firewall is suppressing them.
- **risks:** AWS security group config, not VXLAN misconfiguration, is likely root cause.

---

## L032 — Kubernetes: cross-node pod connectivity fails with Flannel VXLAN on RHEL 8

- **source_url:** https://github.com/kubernetes/kubernetes/issues/121530
- **date:** October 2023
- **project/community:** Kubernetes / Flannel
- **exact_symptom:** Same-node pods communicate fine; different-node pods can't connect. Cross-node pod-to-pod traffic fails entirely.
- **environment:** Kubernetes v1.26.9, RHEL 8.6, Flannel VXLAN backend
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION or VXLAN_FRAGMENTATION_OBSERVED — cross-node failure with same-node success is consistent with VXLAN encap MTU issues.
- **confidence:** medium
- **active:** yes
- **contact_method:** issue reply
- **suggested_opening:** The same-node works / cross-node fails pattern with Flannel VXLAN is a common MTU blackhole indicator — vxlan-tracer would confirm within 30 seconds whether VXLAN fragmentation is the root cause on your RHEL 8.6 nodes.
- **risks:** Root cause may be firewalld blocking VXLAN UDP port 8472; vxlan-tracer rules out MTU.

---

## L033 — Cilium native routing: ICMP echo with fragmented payload consistently dropped

- **source_url:** https://github.com/cilium/cilium/issues/45339
- **date:** April 2026
- **project/community:** Cilium
- **exact_symptom:** In Cilium Native Routing Mode, ICMP Echo Requests with payload sizes triggering IP fragmentation are consistently dropped by the Cilium BPF datapath for payloads > 1472 bytes.
- **environment:** Cilium native routing, no encapsulation, Linux kernel 5.15+
- **vxlan_tracer_relevance:** VXLAN_FRAGMENTATION_OBSERVED (analogous) — same BPF hooks suppress fragments on VXLAN path. In VXLAN mode the same behavior would suppress oversized VXLAN packets.
- **confidence:** medium
- **active:** yes (very recent)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer's TC attachment observes equivalent fragmentation drops on the VXLAN datapath — if you have any VXLAN deployments, running vxlan-tracer would confirm whether BPF fragmentation drops are happening there too.
- **risks:** Issue is native routing, not VXLAN — note this distinction clearly.

---

## L034 — Cilium + Tailscale: TLS handshake fails due to stacked overlay MTU

- **source_url:** https://github.com/tailscale/tailscale/issues/18565
- **date:** January 2026
- **project/community:** Tailscale / Cilium
- **exact_symptom:** TLS handshake fails with EOF errors when running Cilium CNI with VXLAN tunnel mode and MTU 1280 over Tailscale. Server responses never reach the client — large packets exceeding effective MTU dropped mid-handshake.
- **environment:** Cilium VXLAN + Tailscale, MTU 1280, Kubernetes, Linux
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — stacked overlay MTUs (Tailscale + VXLAN) produce effective MTU of ≤1280, causing handshake packets to exceed path capacity.
- **confidence:** high
- **active:** yes (very recent)
- **contact_method:** issue reply
- **suggested_opening:** vxlan-tracer can confirm the effective MTU at the VXLAN layer and whether the Tailscale + VXLAN stacking is causing fragmentation or silent drops for your TLS handshake packets — stacked overlays are a known MTU blackhole category it was designed to detect.
- **risks:** Tailscale adds a layer beyond vxlan-tracer's primary scope; note stacked encapsulation context.

---

## L035 — Calico: constant FELIX_VXLANMTU warning logs about MTU configuration mismatch

- **source_url:** https://github.com/projectcalico/calico/issues/5460
- **date:** 2021 (referenced through 2023)
- **project/community:** Calico
- **exact_symptom:** Warning logs constantly appear in calico-node pod and kernel about VXLAN MTU configuration. Logs indicate FELIX_VXLANMTU mismatches between expected and actual values.
- **environment:** Calico VXLAN, Linux, Kubernetes
- **vxlan_tracer_relevance:** VXLAN_MTU_MISCONFIGURATION — configuration warning is a precursor to fragmentation blackholes. vxlan-tracer confirms whether the warning corresponds to actual packet-level drops.
- **confidence:** medium
- **active:** yes (referenced in 2023)
- **contact_method:** issue reply
- **suggested_opening:** The FELIX_VXLANMTU warning messages suggest a misconfiguration that vxlan-tracer can confirm at the packet level — it would tell you whether the mismatch is causing actual fragmentation or is just log noise.
- **risks:** May be a logging/cosmetic issue with no actual packet-level impact.

---

## Summary

| Metric | Count |
|--------|-------|
| Total leads | 35 |
| High confidence | 14 |
| Medium confidence | 21 |
| Active/open issues | 28 |
| Cilium | 14 |
| Calico | 9 |
| Flannel | 3 |
| Rancher | 3 |
| k3s | 1 |
| KubeVirt | 2 |
| Kubernetes core | 2 |
| Tailscale/other | 1 |

### Verdict distribution

| Verdict | Leads |
|---------|-------|
| PTB_SUPPRESSED | L002, L003, L004, L007, L014, L019, L024, L030, L031 |
| VXLAN_MTU_MISCONFIGURATION | L006, L008, L009, L011, L012, L013, L017, L018, L025, L026, L027, L028, L034, L035 |
| VXLAN_FRAGMENTATION_OBSERVED | L005, L015, L020, L022, L023, L029, L032 |
| Multiple/overlapping | L001, L010, L021, L033 |
