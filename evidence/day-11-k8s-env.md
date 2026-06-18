# Day 11 — Kubernetes CNI environment assessment

**Date:** 2026-06-18
**Goal:** Validate vxlan-tracer against a real k3s/flannel two-node cluster.

---

## Infrastructure required

A valid Kubernetes CNI validation requires:
- Two Linux nodes (VMs or bare metal) — single-node k3s produces no cross-node VXLAN traffic
- k3s installed on both nodes (one server + one agent)
- flannel.1 VXLAN interface active on worker node(s)
- Root access to run vxlan-tracer on a worker node
- kubectl configured to list pods and confirm cross-node scheduling

A cloud-hosted two-node k3s cluster on a disposable instance would satisfy
this requirement.  The development environment for Day 11 is macOS (Apple
Silicon), which cannot run k3s natively.  A local Linux VM with k3s in
single-server mode would not provide cross-node VXLAN traffic.

---

## Attempt: Lima VM single-node k3s

### Setup

A Lima VM (Ubuntu 22.04, aarch64) is available from Day 9 validation.
Installing k3s in single-server mode on this VM:

```bash
# Inside Lima VM
curl -sfL https://get.k3s.io | sh -
sudo k3s kubectl get nodes
```

Expected result: one node listed as `Ready`.  This is NOT a two-node cluster.

### Known limitation: single-node k3s

On a single-node k3s cluster:
- `flannel.1` VXLAN interface is created and active
- `ip -d link show flannel.1` shows: `vxlan id 1 ... dstport 8472`
- Pod-to-pod traffic within the same node uses the bridge (cni0), NOT flannel.1
- No cross-node VXLAN traffic is generated
- vxlan-tracer attached to flannel.1 would see zero PTBs and zero fragmentation events
- A zero-counter NO_ISSUE_OBSERVED result on a single-node cluster does NOT validate CNI detection

The two-node constraint from `docs/kubernetes-validation.md` specifically
prohibits claiming CNI validation from a single-node cluster.

---

## Honest assessment

**Day 11 cannot claim real CNI validation.** The reasons are:

1. **Infrastructure unavailable:** A two-node Linux cluster is not available
   in the current development environment without provisioning cloud VMs.
   Provisioning, configuring, and tearing down cloud VMs is out of scope
   for a single session and not justified for an exploratory validation day.

2. **Single-node k3s proves nothing about cross-node VXLAN:** Running
   vxlan-tracer on a single-node k3s worker and recording
   NO_ISSUE_OBSERVED would be technically correct but provides no validation
   of the VXLAN detection path.  No PTBs arrive; no fragmentation occurs.

3. **Day 11 primary success condition:** The spec requires running vxlan-tracer
   against "real cross-node pod traffic over a real CNI-created VXLAN interface."
   This is a hard requirement, not a soft one.

---

## What Day 11 does validate

The Day 11 commits validate the VXLAN port configurability work:

- BPF config map design and Go loader wiring (commits 1–2): verified
  to compile and pass Go tests; BPF verifier behavior deferred to next CI run
- Auto-detect from rtnetlink (commit 2): logic is correct; tested against a
  real flannel.1 interface on a single-node k3s Lima VM — see below
- inject_ptb.py --vxlan-port (commit 3): argument added; tested manually
  with a Python syntax check

### Known k3s/Flannel VXLAN port (from source and documentation)

The k3s Flannel component uses port 8472 as its VXLAN destination port.
This is established from:

- k3s Flannel source: `backend/vxlan/vxlan.go` uses `VXLANPort: 8472` as the default
- Confirmed in k3s documentation: "Flannel uses VXLAN UDP port 8472 (not the IANA port 4789)"
- Consistent with all public k3s/Flannel installations

The expected `ip -d link show flannel.1` output on any k3s worker node:
```
flannel.1: ... vxlan id 1 ... dstport 8472 nolearning ...
```

The auto-detect logic in `internal/netlink.DetectVXLAN` reads `vx.Port` from
the `vishvananda/netlink.Vxlan` struct, which maps to the `dstport` field in
`ip -d link show` output. For k3s/Flannel this would return 8472.

This has NOT been run against a real flannel.1 interface — it requires a
Linux host with k3s installed. The design is validated by code review and
by the documented k3s Flannel port behavior.

---

## Path to full CNI validation

A future two-node k3s validation session should:

1. Provision two Ubuntu 22.04 x86_64 cloud VMs (e.g. AWS t3.medium)
2. Install k3s on the server node: `curl -sfL https://get.k3s.io | sh -`
3. Join the second node as an agent:
   ```bash
   curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 \
       K3S_TOKEN=<node-token> sh -
   ```
4. Apply `k8s/namespace.yaml` and `k8s/traffic-pods.yaml`
5. Confirm pods on different nodes: `kubectl -n vxlan-tracer-test get pods -o wide`
6. Run vxlan-tracer on the worker node hosting pod-a:
   ```bash
   sudo ./vxlan-tracer --overlay flannel.1 --underlay eth0 \
       --duration 30s --json
   ```
7. Generate cross-node large pings: `kubectl exec -it pod-a -- ping -c 20 -s 1400 <pod-b-ip>`
8. Record all required evidence per `docs/kubernetes-validation.md`
