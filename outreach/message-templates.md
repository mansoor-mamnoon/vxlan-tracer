# Message Templates + Personalized Drafts

**Status:** Drafts only. Do not send without explicit approval.
**Rule:** Every message must be personalized to the specific issue context. Generic "have you tried my tool" messages are worse than silence.

---

## Context templates

### Template A — PTB_SUPPRESSED (firewall/policy drops PTB before kernel)

For issues where the reporter describes:
- PTB / fragmentation-needed messages not reaching pods
- Firewall or eBPF policy dropping ICMP type 3 code 4
- Large packets not triggering any PTB response

> I'm working on [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer), a small eBPF diagnostic tool for exactly this class of problem. It attaches a TC sched_cls hook on the underlay ingress path (before netfilter) and a kprobe on `icmp_rcv` (after netfilter), and compares the two counts. If TC > 0 and `icmp_rcv` = 0, it reports `PTB_SUPPRESSED` — meaning the PTB arrived at the NIC but was dropped before the kernel could act on it. That gap between the two hooks is where your [firewall/policy] drop would show up.
>
> It's an experimental prerelease, lab-validated on kernels 5.15–6.8 (amd64 and arm64), not yet tested against a real [CNI] cluster. If you're on a staging or non-critical node and want to try it, the amd64/arm64 binaries are at [releases page].
>
> Happy to answer questions about what it reports if you run it.

---

### Template B — VXLAN_MTU_MISCONFIGURATION (wrong interface MTU, no active fragmentation yet)

For issues where the reporter describes:
- MTU misconfiguration warnings in CNI logs
- Wrong MTU set on pod veth or overlay interface
- Configuration value doesn't match expected (underlay MTU − 50)

> I'm building [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer), an eBPF diagnostic tool for VXLAN MTU issues. One of its verdicts — `VXLAN_MTU_MISCONFIGURATION` — specifically catches the case you're describing: overlay interface MTU set higher than (underlay MTU − 50 bytes), meaning every large packet will either be fragmented or dropped depending on the DF bit. It checks this without needing any active traffic.
>
> It also has a `vxlan-tracer interfaces` subcommand (no root required) that enumerates VXLAN interfaces on the host with their VNI, port, MTU, and inferred underlay — which would let you quickly verify the MTU on each interface without manually running `ip link show`.
>
> If your [CNI] setup is still exhibiting this, and you have a staging or test node available, it might give you a quick confirmation. It's an experimental prerelease.

---

### Template C — VXLAN_FRAGMENTATION_OBSERVED (active fragmentation confirmed)

For issues where the reporter describes:
- Large packet drops during active traffic
- ip_do_fragment being triggered
- Throughput degradation for large payloads specifically

> I'm working on [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer), an eBPF tool that detects VXLAN fragmentation using two complementary signals: a kprobe on `ip_do_fragment` (which fires when the kernel fragments a packet) and a TC egress hook on the VXLAN overlay (which records the outer packet size). When both signals fire together with outer packets exceeding the underlay MTU, it reports `VXLAN_FRAGMENTATION_OBSERVED` with a `global_corroborated` scope — meaning fragmentation is likely coming from the VXLAN path, not from unrelated traffic.
>
> It's an experimental prerelease, validated in a netns lab on kernels 5.15–6.8. Not yet tested against a real [CNI] cluster, but this is the kind of real-world environment that would be very valuable for validation. If you run it on a staging or non-critical node, the result would be useful to share back — even a "no issue observed" or "tool failed to load" is informative.

---

## Personalized drafts

### Draft 1 — PC01: Cilium/KubeVirt egress gateway fragmentation
**Target:** https://github.com/cilium/cilium/issues/38828

> The symptom you're describing — HTTP responses entering `cilium_vxlan` as egress gateway traffic being fragmented before reaching the destination VM — is exactly what vxlan-tracer was designed to diagnose.
>
> vxlan-tracer attaches TC sched_cls hooks to the `cilium_vxlan` egress path and a kprobe on `icmp_rcv`. The gap between TC ingress count and `icmp_rcv` count tells you whether PTB messages are being generated and then dropped, or never generated at all. For egress gateway traffic specifically, it would tell you whether the fragmentation is happening at the VXLAN encap step (outer packet exceeds underlay MTU) or whether PTBs from the underlay are being suppressed before the originating pod can react.
>
> It's lab-validated on 5.15–6.8 kernels but not yet tested against a real KubeVirt environment — your setup would be a genuinely useful first. If you're able to run it on a non-critical KubeVirt node, I'd be grateful for the result: https://github.com/mansoor-mamnoon/vxlan-tracer

---

### Draft 2 — PC02: Calico random veth MTU 1500 instead of 1400
**Target:** https://github.com/projectcalico/calico/issues/9718

> The random-probability MTU assignment you described (veth MTU 1500 when it should be 1400) is a good use case for vxlan-tracer's `interfaces` subcommand.
>
> `vxlan-tracer interfaces` lists all VXLAN-type interfaces on the host with their MTU and inferred underlay — no root required. On the affected nodes, you could run it to spot which interfaces have MTU 1500 (wrong) vs. 1400 (correct) before running the full diagnostic. The diagnostic itself would then confirm whether those 1500-MTU interfaces are actively producing fragmentation events via `ip_do_fragment`.
>
> If the race condition is hard to reproduce, vxlan-tracer can at least give you a quick MTU audit across interfaces without needing to script `ip link show | grep mtu` manually.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer — experimental prerelease, not yet tested against Calico specifically, but this would be a useful first real-world run.

---

### Draft 3 — PC03: Cilium drops ICMP FragmentationNeeded during eBPF masquerade
**Target:** https://github.com/cilium/cilium/issues/33844

> The "Error while correcting L4 checksum" drop path is interesting for vxlan-tracer's diagnostic split. It attaches both a TC sched_cls hook (pre-netfilter, pre-BPF-masquerade) and a kprobe on `icmp_rcv` (post-netfilter). If PTB messages are arriving at the NIC but getting dropped inside the eBPF masquerade SNAT path, you'd see TC ingress count > 0 with `icmp_rcv` count = 0 — the `PTB_SUPPRESSED` verdict.
>
> This would tell you definitively that the drop is happening between the TC hook and `icmp_rcv`, which is exactly the layer where your SNAT checksum correction runs. It wouldn't fix the Cilium bug, but it would narrow the bug to a specific code path and give you a reproducible test condition.
>
> If you have a Cilium node you can test on, vxlan-tracer is at https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels, amd64 and arm64).

---

### Draft 4 — PC04: KubeVirt slow VM throughput ~80 Mbit/s
**Target:** https://github.com/kubevirt/kubevirt/issues/11646

> 80 Mbit/s is a suspiciously specific ceiling for a network performance issue — that throughput range is often consistent with a PMTUD black hole where large packets are being silently dropped and the TCP sender falls back to a small retransmit window. The symptom pattern (not a percentage slowdown, but a hard ceiling) is characteristic.
>
> vxlan-tracer can rule this in or out in under a minute: if `ip_do_fragment` fires during a large transfer through the VXLAN path, the tool reports `VXLAN_FRAGMENTATION_OBSERVED`. If it doesn't, you can eliminate VXLAN MTU as the throughput ceiling and focus elsewhere.
>
> It's an experimental prerelease, validated on 5.15–6.8 kernels. KubeVirt with Multus would be a novel environment for the matrix. If you run it: https://github.com/mansoor-mamnoon/vxlan-tracer

---

### Draft 5 — PC05: Cilium + Tailscale stacked MTU, TLS EOF
**Target:** https://github.com/tailscale/tailscale/issues/18565

> The stacked-overlay MTU scenario — Tailscale adds overhead on top of VXLAN, reducing the effective path MTU to ≤1280 — is worth diagnosing at each layer separately. vxlan-tracer checks the Cilium VXLAN layer specifically: it measures whether the outer VXLAN packets are exceeding the underlay MTU and whether PTBs from the underlay are reaching `icmp_rcv`.
>
> With Cilium VXLAN at MTU 1280 over Tailscale, vxlan-tracer would almost certainly report `VXLAN_MTU_MISCONFIGURATION` — the overlay MTU (1280) needs to account for both Tailscale overhead and VXLAN overhead (50 bytes), so the safe effective MTU might be 1280 − 50 = 1230 bytes or lower. Whether Tailscale is also doing further encapsulation overhead is a separate question.
>
> It's an experimental prerelease, not yet tested in a Tailscale + Cilium stacked scenario, which is exactly why this would be a valuable run: https://github.com/mansoor-mamnoon/vxlan-tracer

---

### Draft 6 — PC06: Calico eBPF + VXLAN + GRO, GSO size not adjusted
**Target:** https://github.com/projectcalico/calico/issues/11160

> The BPF_F_ADJ_ROOM_FIXED_GSO interaction you're describing means GRO-recombined packets arrive at the VXLAN encap point without GSO size adjustment — they're super-MTU at the TC egress hook.
>
> vxlan-tracer's TC egress hook is attached at exactly that point on the VXLAN overlay egress path. It records the outer packet size seen at the hook. If GRO-recombined packets are causing the issue, the hook would report `max_outer_ip_len` significantly above the underlay MTU, and `ip_do_fragment` would be firing at high frequency. The combined verdict would be `VXLAN_FRAGMENTATION_OBSERVED` with `fragmentation_scope: global_corroborated`.
>
> This would give you packet-level evidence from the TC layer to go alongside the BPF verifier/program analysis. If you want to try it: https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels, amd64 + arm64).

---

### Draft 7 — PC07: Cilium LoadBalancer PTB messages loop on k8s host
**Target:** https://github.com/cilium/cilium/issues/34380

> The "PTBs looping on the k8s host until TTL expires" behavior is exactly what vxlan-tracer's TC / kprobe split is designed to catch.
>
> It attaches TC sched_cls on the underlay ingress path (this hook fires before netfilter, before any eBPF policy, at the NIC driver level) and a kprobe on `icmp_rcv` (which fires when the kernel actually receives the ICMP packet for processing). If PTBs arrive at TC but never reach `icmp_rcv`, the tool reports `PTB_SUPPRESSED`. If they arrive at both hooks, it's `PTB_DELIVERED`.
>
> For your LoadBalancer scenario, the PTBs generated by the external load balancer would arrive at the underlay ingress. If they're being looped rather than forwarded to the pod, you'd expect to see TC ingress count > 0 but `icmp_rcv` count = 0 — which would confirm the drop is in the netfilter/eBPF layer between the NIC and the kernel's ICMP handler.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer — experimental prerelease, 5.15–6.8 kernels.

---

### Draft 8 — PC08: k3s/Flannel WireGuard wrong MTU on Azure (1420 instead of 1350)
**Target:** https://github.com/k3s-io/k3s/issues/5101

> One note upfront: vxlan-tracer is VXLAN-specific (not WireGuard), so this is a partial match — but the MTU arithmetic problem is identical.
>
> If your k3s cluster also has any VXLAN-mode interfaces (or if you've switched to the VXLAN backend to work around this), vxlan-tracer would immediately flag the 1420 MTU as a misconfiguration: underlay MTU (1400 on Azure) minus VXLAN overhead (50 bytes) = 1350, so anything above 1350 on the overlay is risky. The tool reports this as `VXLAN_MTU_MISCONFIGURATION` without needing any active traffic.
>
> For the WireGuard path specifically, the same arithmetic applies (WireGuard overhead is 32 bytes for Noise, not 50). vxlan-tracer can't attach to a WireGuard interface directly, but it can confirm the VXLAN layer is correctly configured even when WireGuard is layered on top.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer if it's useful context.

---

### Draft 9 — PC09: Calico NodePort TCP payload > 65KB hangs 60s on VMware
**Target:** https://github.com/projectcalico/calico/issues/8349

> The 60-second delay is the TCP retransmit timeout — the sender has given up on the first transmission and is waiting for its full backoff interval before retrying. This is the signature of a PMTUD black hole: the oversized packet is dropped silently, the PTB that would tell the sender to reduce its segment size never arrives, and the sender waits 60 seconds for the packet to be acknowledged before it assumes loss.
>
> vxlan-tracer checks specifically for PTB suppression: TC sched_cls counts PTBs at the NIC, kprobe counts PTBs at `icmp_rcv`. If the suppression is happening between those two points, the verdict is `PTB_SUPPRESSED`. For VMware vSphere environments, the VXLAN underlay MTU is often set differently from bare metal — 1400 or 1450 rather than 1500 — and the Calico VXLAN overlay needs to account for that.
>
> If you have a VMware + Calico eBPF node you can run it on: https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels).

---

### Draft 10 — PC10: Cilium AllowICMPFragNeeded ignored when ingress policy present
**Target:** https://github.com/cilium/cilium/issues/26193

> The diagnostic question here is whether PTBs are being dropped before the BPF policy evaluates them (at the TC layer) or after (inside the BPF ingress path). vxlan-tracer's TC hook fires at the NIC, before any eBPF or netfilter processing, so it captures PTBs that arrive regardless of policy. The `icmp_rcv` kprobe fires after all that processing.
>
> If TC count > 0 and `icmp_rcv` = 0, the drop is in the BPF ingress path — which would mean `AllowICMPFragNeeded` is being applied too late or incorrectly evaluated. If TC = 0, the PTBs aren't arriving from the underlay at all (a different problem).
>
> That split would give you a concrete answer about where in the stack the flag's enforcement is failing. If you want to try it: https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels, amd64 + arm64).

---

### Draft 11 — PC11: Calico multi-NIC wrong source IP in ICMP MTU-too-big
**Target:** https://github.com/projectcalico/calico/issues/4439

> The multi-NIC misdirection scenario is interesting for vxlan-tracer's measurement. It attaches to a specific underlay interface, so if PTBs are arriving on a different interface than expected, the TC count would be 0 on the primary interface but potentially > 0 if you attach on the secondary. By running vxlan-tracer on different underlay interfaces, you can determine which interface the misdirected PTBs are actually arriving on — which confirms or refutes the "wrong source IP causes wrong routing" hypothesis.
>
> It's not a perfect fit (designed for single overlay + single underlay), but the ability to select the underlay interface via `--underlay` might let you probe each NIC separately.
>
> If useful context: https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease).

---

### Draft 12 — PC12: Cilium CFP — IP fragmentation and PMTUD generally broken
**Target:** https://github.com/cilium/cilium/issues/43072

> While the long-term fix is being designed, it might be useful to have a per-node diagnostic that gives operators a verdict today.
>
> vxlan-tracer does exactly this: it attaches TC sched_cls and kprobes on a specific overlay/underlay pair and produces one of five verdicts — PTB_SUPPRESSED, PTB_DELIVERED, VXLAN_FRAGMENTATION_OBSERVED, VXLAN_MTU_MISCONFIGURATION, or NO_ISSUE_OBSERVED. It's validated on 5.15–6.8 kernels (amd64 and arm64) but not yet against a real Cilium cluster.
>
> I'm not suggesting it as a solution to the design problem — more as a diagnostic that could help operators verify whether their specific cluster is affected and which path (E/W vs. N/S, which node) is the source. https://github.com/mansoor-mamnoon/vxlan-tracer if it's relevant to the CFP discussion.

---

### Draft 13 — PC13: Flannel docker0 MTU 1500, DinD builds hang
**Target:** https://github.com/flannel-io/flannel/issues/1171

> If you're still hitting this in 2025–2026, vxlan-tracer would give you a definitive answer in under a minute. The docker0 (1500) vs. flannel.1 (1450) MTU mismatch is exactly `VXLAN_MTU_MISCONFIGURATION` — running `vxlan-tracer --overlay flannel.1 --underlay eth0` on a node would confirm whether the MTU mismatch is actively causing fragmentation and show you the recommended overlay MTU to fix it.
>
> The `interfaces` subcommand (`vxlan-tracer interfaces`, no root required) also lists flannel.1 with its current MTU and inferred underlay, which makes it easy to verify the configuration before running the full diagnostic.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer — experimental prerelease, validated on 5.15–6.8 kernels.

---

### Draft 14 — PC14: KubeVirt VM NIC doesn't know about VXLAN overhead
**Target:** https://github.com/kubevirt/kubevirt/issues/987

> The DHCP MTU option workaround you proposed would fix the VM's advertised MTU, but it's worth confirming that the VXLAN path itself is also correctly configured on the host side. If the tap interface MTU on the node doesn't match the VXLAN path MTU, packets from the VM may still exceed the VXLAN payload limit even if the VM's TCP stack thinks they're within MTU.
>
> vxlan-tracer can confirm the host-side picture: it checks the overlay interface MTU vs. (underlay MTU − 50 bytes) and reports whether the path is correctly configured. If you run it on a node where KubeVirt VMs are experiencing TCP timeouts, it would tell you whether the MTU problem is in the VM, on the node's VXLAN path, or somewhere on the underlay.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels, amd64 + arm64).

---

### Draft 15 — PC15: Calico periodic vxlan.calico drops every 40-60 minutes
**Target:** https://github.com/projectcalico/calico/issues/5696

> The 40-60 minute periodicity is interesting — that timescale matches ARP/FDB cache expiry on some configurations, but it could equally be a traffic-pattern-driven MTU boundary hit (a batch job or cron task that generates large packets periodically). vxlan-tracer can rule in or out the MTU hypothesis quickly.
>
> If you run it during an affected window with `--duration 300s` (or longer), it will tell you whether `ip_do_fragment` is firing during the drop period. If fragmentation events spike during the 40-60 minute window, the verdict would be `VXLAN_FRAGMENTATION_OBSERVED` — which would point at MTU as the cause. If fragmentation is zero during the drop period, that rules out MTU and points at ARP/FDB or something else.
>
> https://github.com/mansoor-mamnoon/vxlan-tracer (experimental prerelease, 5.15–6.8 kernels, amd64 + arm64).
