# Day 12 — k3s two-node cluster availability probe

**Date:** 2026-06-18
**Status: NOT RUN — no k3s cluster available**

---

## Probe results

### Lima VM (vxlan-test, Ubuntu 22.04.5 LTS, 5.15.0-181-generic)

```
$ which k3s     → k3s not found
$ which kubectl → kubectl not found
```

k3s is not installed in the Lima VM. There is no single-node k3s instance,
no flannel CNI, and no kubeconfig. The VM is a plain Ubuntu 22.04 environment
used for eBPF kernel-space testing only.

### macOS host

```
$ which k3s     → k3s not found on macOS host
$ which kubectl → /usr/local/bin/kubectl
$ kubectl get nodes → "couldn't get current server API group list: the server could not find the requested resource"
```

`kubectl` is installed (likely from a previous unrelated project) but points to
a cluster that is not reachable. There is no active Kubernetes cluster context
with a working API server.

---

## Why two-node validation was not attempted

Cross-node pod traffic validation requires:

1. **Two nodes** — a sending pod on node A and a receiving pod on node B.
   Single-node k3s routes pod-to-pod traffic in-process (same kernel); the
   VXLAN underlay path is never exercised for same-node pods.

2. **Real VXLAN traffic** — flannel VXLAN encapsulation only occurs for
   cross-node traffic. A one-node cluster never generates VXLAN packets.

3. **Root access on the node** — to load eBPF programs via `nsenter` or
   `kubectl debug node/...`.

None of these conditions are met from a macOS development environment with a
Lima single-purpose VM. Provisioning a two-node k3s cluster (via k3d, Vagrant,
or two distinct cloud VMs) is outside the scope of the current environment.

---

## What this means for the project

The k3s/flannel CNI validation path documented in `docs/kubernetes-validation.md`
remains **not exercised**. This is honestly documented and was known at the start
of Day 12.

The netns lab (Day 12 commits 1–6) proves the diagnostic logic — BPF port
matching, auto-detect, PTB counting — on a real Linux kernel. The CNI layer
(flannel pod CIDR assignment, cross-node VXLAN routing, kube-proxy iptables)
adds no new BPF code paths; it is plumbing that determines which packets arrive
on the underlay interface.

Claims NOT made:
- k3s/flannel cross-node MTU blackhole detected (NOT verified)
- vxlan-tracer works inside a k3s node pod (NOT verified)
- Flannel-specific iptables suppression detected (NOT verified)
