# Technical Post: Diagnosing VXLAN MTU Blackholes with eBPF

**Draft — do not publish without approval.**
**Platform:** Hacker News / dev.to / personal blog

---

## Diagnosing VXLAN MTU Blackholes with eBPF

If you've ever had a Kubernetes cluster where ping works but `kubectl cp` hangs, or where small HTTP responses succeed but large file downloads stall silently, you may have hit a VXLAN MTU blackhole. This post explains what causes them, why they're hard to debug with standard tools, and how an eBPF-based approach can give you a definitive verdict in under a minute.

---

### The symptom

The failure mode is frustratingly non-obvious:

- `ping` works
- Small HTTP responses work
- `kubectl exec` works
- `kubectl cp` of a large file: hangs after a few kilobytes
- Large API response payloads: silently truncated or stalled
- No error in application logs

The reason is VXLAN encapsulation overhead. A VXLAN outer frame is 50 bytes larger than the inner payload (outer ETH 14 + IP 20 + UDP 8 + VXLAN header 8). If your overlay interface MTU is 1500 and your underlay MTU is also 1500, a 1500-byte inner IP packet becomes a 1550-byte outer IP packet — 50 bytes over the underlay MTU.

What happens next depends on the DF (Don't Fragment) bit on the outer IP header:

- **DF=0 (Linux VXLAN default):** The kernel fragments the oversized packet. Fragmented UDP VXLAN is commonly dropped silently by cloud fabric (AWS VPC, GCP VPC, Azure VNET). In a local lab, fragments may reassemble — but in cloud environments they're gone.
- **DF=1 (ICMP PTB path):** The underlay router generates an ICMP "fragmentation needed" (PTB) message back to the sender. If the PTB reaches the kernel, PMTUD kicks in and the sender reduces its segment size. If the PTB is dropped (by a firewall, a netfilter rule, or an eBPF policy), the sender never gets the signal and keeps retrying the same oversized packet until the TCP retransmit timeout fires (60 seconds of silence).

Both paths produce silent packet loss. The DF=0 path is harder to diagnose because it doesn't even generate a PTB — you need to observe the fragmentation event itself.

---

### Why standard tools don't catch this

`tcpdump` can capture PTBs, but it runs post-netfilter for AF_PACKET sockets. A PTB that was dropped by an iptables INPUT rule won't appear in a tcpdump capture on the same interface it arrived on. You'd need a raw socket or XDP hook to capture it pre-netfilter, which is non-trivial to set up on a live node.

`ip -s link show` shows general interface statistics including drops, but doesn't distinguish between PTB drops and other drop causes.

Examining iptables/nftables rules for ICMP type 3 code 4 requires understanding the full rule chain, including any CNI-generated rules that may not be documented.

PMTU cache inspection (`ip route get <dst>`) shows the current PMTU estimate but not whether it was derived from an actual PTB or whether PTBs are currently being suppressed.

---

### The eBPF approach

The core insight is that an ICMP "fragmentation needed" message passes through two observable kernel points before it reaches the pod:

1. **TC sched_cls ingress hook** — fires at the underlay NIC, before netfilter, before any iptables or eBPF policy
2. **`icmp_rcv` kprobe** — fires when the kernel's ICMP handler receives the packet (after netfilter)

If count(1) > 0 and count(2) = 0, something between the NIC and `icmp_rcv` is dropping the PTB. This is the `PTB_SUPPRESSED` verdict.

For the DF=0 fragmentation path, there's no PTB, but there is `ip_do_fragment` — the kernel function that fragments packets when DF=0. A kprobe on this function fires every time a packet is fragmented. Separately, the TC egress hook on the VXLAN overlay interface records the outer packet size before encapsulation. When both `ip_do_fragment` fires AND the outer packet size exceeds the underlay MTU, the two signals together indicate `VXLAN_FRAGMENTATION_OBSERVED` with corroborated scope.

---

### Limitations

`ip_do_fragment` is a global kernel function — it fires for all IP fragmentation on the host, not just VXLAN traffic. On a busy host with non-VXLAN fragmentation (IPsec, GRE, other tunnels), the fragmentation counter will be inflated. The TC egress corroboration mitigates this — if the TC hook simultaneously sees oversized outer VXLAN packets, the two signals together are more specific.

VXLAN-per-namespace or per-VNI attribution is not possible with the current BPF helper set. `bpf_get_netns_cookie` is not available for TC sched_cls or kprobe program types on any tested kernel (5.15 through 6.10). So the tool sees host-wide events, not pod-specific events. This is a known limitation.

The tool has not been tested against a real CNI cluster (k3s/Flannel, Calico, Cilium). It has been validated in a controlled netns lab on four kernels: 5.15.0-181-generic (aarch64), 6.10.14-linuxkit (aarch64), 6.8.0-1052-azure (x86_64), 6.8.0-1059-azure (x86_64). All five verdict paths execute end-to-end in that environment.

---

### Using it

```sh
# From the release archive (Linux, root required)
tar -xzf vxlan-tracer-linux-amd64.tar.gz
cd vxlan-tracer-linux-amd64

# Discover your VXLAN interfaces (no root required)
./vxlan-tracer interfaces

# Verify prerequisites
sudo bash scripts/preflight.sh

# Run the diagnostic (30 second window)
sudo ./vxlan-tracer --overlay flannel.1 --underlay eth0 --duration 30s
```

Example output for the fragmentation case:

```
Verdict:  VXLAN_FRAGMENTATION_OBSERVED
Evidence:
  ip_do_fragment events:   6
  largest outer IP seen:   1438 B
  underlay MTU:            1400 B  (outer packet exceeded by 38 B)
Recommendation:
  set overlay MTU to 1350 B or lower
  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)
Scope:
  global fragmentation counter corroborated by VXLAN TC egress
  (both ip_do_fragment and oversized outer packets observed)
```

---

### Source and prerelease

vxlan-tracer is at https://github.com/mansoor-mamnoon/vxlan-tracer. v0.1.0-rc1 is available as a prerelease with amd64 and arm64 Linux binaries. The tool is MIT-licensed.

If you have a VXLAN-based overlay network and encounter large-packet stalls, I'd be interested to hear what verdict the tool produces in your environment. The kernel matrix currently covers 5.15–6.10 on aarch64 and x86_64, but real CNI environments (Flannel, Calico, Cilium) have not been tested.

---

*This is an experimental prerelease. The tool is not production-ready and has not been tested in production environments. Do not run on production nodes. The fragmentation scope limitation described above means the tool's verdict is a hypothesis, not a guarantee.*
