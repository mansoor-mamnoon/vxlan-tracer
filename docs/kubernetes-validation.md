# Kubernetes CNI validation requirements

This document defines what constitutes a valid vxlan-tracer Kubernetes test,
what evidence must be recorded, and what claims can and cannot be made.

---

## Two-node requirement

A single-node Kubernetes cluster produces no cross-node VXLAN traffic.
Pod-to-pod communication within the same node is handled by the bridge
or local routing; VXLAN encapsulation is only used for cross-node traffic.

**A single-node validation proves nothing about VXLAN behavior.**
A valid Kubernetes validation requires at minimum:

1. Two Linux nodes with the CNI overlay active.
2. One pod running on each node (different `spec.nodeName` values).
3. Traffic between those pods that provably transits the VXLAN interface
   (`ip -d link show` confirming the interface type and dstport; VXLAN
   counters increasing during the test window).

### Proof checklist

Before claiming Kubernetes/CNI validation, every item below must be recorded:

- [ ] `uname -a` from both nodes (kernel version + architecture)
- [ ] `kubectl get nodes -o wide` (shows node IPs)
- [ ] `kubectl get pods -o wide` (shows which node each pod runs on — must be different)
- [ ] `ip -d link show <overlay>` from one worker node, confirming:
  - `type vxlan`
  - `id <VNI>` (non-zero)
  - `dstport <PORT>` (the actual port used; do NOT assume 4789)
- [ ] VXLAN interface name (e.g. `flannel.1`, `vxlan.calico`, `vxlan_sys_4789`)
- [ ] Underlay interface name (e.g. `eth0`, `ens5`, `enp3s0`)
- [ ] Traffic confirmation: `ip -s link show <overlay>` TX/RX counters increase
      during cross-node pod ping
- [ ] vxlan-tracer startup log showing detected port and VNI

---

## CNI-specific notes

### k3s / Flannel

k3s bundles Flannel. The default VXLAN port in k3s Flannel is **8472**,
not 4789. The overlay interface is typically `flannel.1`.

```bash
# Confirm on a k3s worker node:
ip -d link show flannel.1
# Expected: "vxlan id 1 ... dstport 8472 ..."
```

Pass `--vxlan-port 8472` to vxlan-tracer, or use the default 0 (auto-detect
reads the port from the interface via rtnetlink).

### Calico VXLAN

Calico uses VXLAN when configured in VXLAN mode (not BGP mode). The interface
is typically `vxlan.calico` or `vxlan_sys_4789`. Port is 4789 (IANA default).

### Cilium

Cilium uses VXLAN in its default mode. Interface is `cilium_vxlan`. Port is
4789. Cilium also supports Geneve (not VXLAN) in some configurations — confirm
with `ip -d link show cilium_vxlan`.

---

## MTU mismatch injection in a CNI environment

**WARNING: Do not modify MTU on production nodes.** Use a disposable cluster.

To inject a controlled MTU fault:

```bash
# On the node running pod A: reduce the underlay MTU
sudo ip link set <underlay-iface> mtu 1400

# Leave the overlay MTU at 1450 (or whatever the CNI set it to)
# This creates: overlay 1450 → outer IP 1500 > underlay 1400 → fragmentation
```

To restore:
```bash
sudo ip link set <underlay-iface> mtu 1500  # or original value
```

The CNI overlay MTU is typically managed by the CNI agent (flannel daemon,
calico-node). After restoring, the CNI may reset the overlay MTU automatically.

---

## What constitutes CNI validation (strict definition)

A CNI validation entry is only valid when ALL of the following are true:

1. **Two nodes confirmed.** `kubectl get pods -o wide` shows pods on different nodes.
2. **VXLAN interface confirmed.** `ip -d link show` shows type=vxlan and dstport.
3. **Traffic crosses nodes.** TX/RX counters on the VXLAN interface increase
   during the test — or a tcpdump/pcap shows VXLAN-encapsulated packets.
4. **vxlan-tracer attaches successfully.** No attach error; BPF programs load.
5. **Verdict is produced.** JSON output or human-readable verdict recorded.
6. **Evidence is recorded.** All items in the proof checklist above are documented.

The following are NOT sufficient for CNI validation:

- Running vxlan-tracer on a single-node cluster.
- Running against a veth/netns lab and calling it "Kubernetes-like."
- Running against the right interface but without confirming cross-node traffic.
- Claiming a CNI-specific verdict without `ip -d link` proof of a real VXLAN device.

---

## MTU behavior to expect in a CNI environment

Cloud providers typically limit packet sizes at the physical network layer.
In AWS/GCP/Azure, the underlay MTU is usually 1500 at the VM level, but
the physical fabric may silently drop or fragment packets at 1500 bytes.

If the cloud provider also sets up jumbo frames (9001 bytes in AWS), the
underlay MTU on the VM may be 9001. In this case:
- Flannel overlay MTU = 9001 - 50 = 8951
- No fragmentation expected for typical traffic

If the cloud provider MTU is 1500:
- Flannel overlay MTU should be 1450 (1500 - 50)
- If misconfigured at 1500, outer IP = 1550 > 1500 → fragmentation or blackhole

**The CNI may clamp the MTU correctly, preventing the fault.** If the overlay
MTU is already set correctly by the CNI (overlay = underlay - 50), vxlan-tracer
will report NO_ISSUE_OBSERVED or VXLAN_MTU_MISCONFIGURATION with no fragmentation.
This is correct behavior, not a tool failure.

---

## References

- `docs/lab-topology.md` — single-node netns lab (no Kubernetes required)
- `docs/reproducibility.md` — Docker quickstart and capability requirements
- `docs/fragmentation-scoping.md` — why ip_do_fragment counts are global
- `evidence/day-11-k8s-env.md` — real k3s environment record (if/when run)
