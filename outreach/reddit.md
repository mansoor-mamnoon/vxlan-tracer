# Reddit post drafts

**Draft — do not post without approval.**

---

## r/kubernetes

**Title:** Tool for diagnosing VXLAN MTU blackholes – kubectl cp hangs, large transfers stall

**Body:**

Built a small eBPF diagnostic for a problem I kept hitting: in Kubernetes clusters using VXLAN overlays, small requests work fine but large transfers (kubectl cp, big API responses, file downloads) silently hang.

The root cause is almost always MTU misconfiguration. VXLAN encapsulation adds 50 bytes of overhead; if the overlay MTU is left at 1500 to match the underlay, every large packet triggers fragmentation — and fragmented VXLAN UDP is commonly dropped silently by cloud VPC routing.

**vxlan-tracer** attaches eBPF to the VXLAN overlay egress and underlay ingress, plus kprobes on `ip_do_fragment` and `icmp_rcv`, and tells you which scenario you're in:

- Fragmentation actively occurring
- ICMP "packet too big" messages being suppressed before the pod sees them
- MTU misconfiguration detected statically (no traffic needed)
- No issue

New in v0.1.0-rc1: `vxlan-tracer interfaces` lists all VXLAN interfaces on your host (VNI, port, MTU, underlay) without needing root. Useful before running the full diagnostic.

GitHub: https://github.com/mansoor-mamnoon/vxlan-tracer

**Caveats:** Experimental prerelease. Validated in a controlled netns lab on 4 kernels (5.15–6.10, amd64 + arm64). Not yet tested on a real k3s, Flannel, Calico, or Cilium cluster. If you run it on a staging node and share the result, that would genuinely help.

---

## r/sysadmin

**Title:** eBPF tool for VXLAN MTU issues – for when large packets die silently

**Body:**

Posting this in case anyone else has spent hours debugging why small pings work but anything over ~1400 bytes drops silently in a Linux-based overlay network.

The problem is VXLAN overhead. The outer VXLAN frame is 50 bytes larger than the inner packet. If the overlay MTU isn't set to (underlay MTU − 50), oversized packets get fragmented at the kernel level — and then fragmented UDP VXLAN is dropped by most cloud networking fabric without any error.

I built a small diagnostic tool that uses eBPF to observe this directly. It attaches kernel hooks to count fragmentation events and ICMP "packet too big" message delivery, and outputs a verdict: is fragmentation happening, are PTB messages being suppressed, or is the MTU just misconfigured.

Prerelease, Linux only, needs root, amd64 and arm64: https://github.com/mansoor-mamnoon/vxlan-tracer/releases/tag/v0.1.0-rc1

Not production-validated — only tested in a lab so far. But if you're chasing a large-packet stall and the usual tools (tcpdump, iptables inspection) haven't found it, this might point you in the right direction.

---

**Notes:**
- r/kubernetes post is more technical; r/sysadmin post is more problem-focused
- Both include the experimental/prerelease caveat prominently
- Don't include the HN technical depth in Reddit posts — they're skimmable
