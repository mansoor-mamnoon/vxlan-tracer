# Kubernetes forum / discuss.kubernetes.io post draft

**Draft — do not post without approval.**
**Target:** discuss.kubernetes.io or Kubernetes Slack #troubleshooting

---

## discuss.kubernetes.io post

**Category:** Networking
**Title:** vxlan-tracer: eBPF tool for diagnosing VXLAN MTU blackholes (prerelease, looking for testers)

**Body:**

Sharing an experimental tool for a networking problem that comes up repeatedly in Kubernetes clusters using VXLAN overlays.

**The problem:** Small requests work. Large requests (kubectl cp, big API payloads, file downloads) silently stall or hang. No error in logs.

**Why it's hard to debug:** VXLAN encapsulation adds 50 bytes of overhead. If the overlay MTU is left at 1500 when the underlay is also 1500, large inner packets produce 1550-byte outer packets that exceed the underlay MTU. The kernel either fragments them (fragmented UDP VXLAN is dropped by most cloud VPC routing silently) or generates an ICMP "packet too big" that gets dropped by a firewall rule before the pod can act on it. Both paths produce silent packet loss.

**What vxlan-tracer does:** Attaches eBPF programs to:
- TC sched_cls on the VXLAN overlay egress — records outer packet size before encapsulation
- TC sched_cls on the underlay ingress — counts PTB messages arriving before netfilter
- kprobe on `ip_do_fragment` — counts fragmentation events
- kprobe on `icmp_rcv` — counts PTBs after netfilter

Compares the counts and produces one verdict: `VXLAN_FRAGMENTATION_OBSERVED`, `PTB_SUPPRESSED`, `PTB_DELIVERED`, `VXLAN_MTU_MISCONFIGURATION`, or `NO_ISSUE_OBSERVED`.

New: `vxlan-tracer interfaces` (no root required) enumerates all VXLAN-type interfaces on the host with their VNI, port, MTU, and inferred underlay — so you know the right values for `--overlay` and `--underlay`.

**Status:** v0.1.0-rc1 prerelease. Lab-validated on 4 kernels (5.15 through 6.10, aarch64 and x86_64). Not yet tested against a real CNI cluster — no Flannel, Calico, Cilium, or k3s validation has been done.

**Ask:** If you have a staging or non-critical node in a VXLAN-based cluster (Flannel, Calico VXLAN mode, Cilium VXLAN tunnel mode), I'd be interested in real-world run results — any verdict, including "no issue observed" or "failed to load". This is the part the lab setup can't cover.

GitHub: https://github.com/mansoor-mamnoon/vxlan-tracer
Release: https://github.com/mansoor-mamnoon/vxlan-tracer/releases/tag/v0.1.0-rc1

Linux only, requires root for the full diagnostic (no root needed for `vxlan-tracer interfaces`). MIT licensed.

---

## Kubernetes Slack #troubleshooting message

**Context:** Post in a thread where someone is reporting large-packet stalls, not as a top-level message.

> If you're hitting the large-packet hang / kubectl cp stall pattern in a VXLAN overlay, there's a prerelease eBPF diagnostic that might help narrow it down. vxlan-tracer attaches to the VXLAN path and tells you whether you're getting fragmentation, PTB suppression, or MTU misconfiguration: https://github.com/mansoor-mamnoon/vxlan-tracer — experimental, not CNI-validated yet, but the symptom match is direct.

**Notes:**
- Slack message must be contextual (reply to an existing thread) — never a cold top-level message
- forum.kubernetes.io has ~500 active users; SIG-Network folks read it
- Don't post in #general or #announcements without explicit permission
