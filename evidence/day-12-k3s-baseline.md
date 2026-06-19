# Day 12 — k3s CNI baseline validation

**Date:** 2026-06-18
**Status: NOT RUN — prerequisite not met (no two-node cluster)**

---

## Prerequisite

This step requires a running k3s cluster with at least two nodes and flannel
VXLAN CNI active. As documented in `evidence/day-12-k3s-env.md`, no such
cluster is available in the current environment.

---

## Procedure (documented for future execution)

When a two-node k3s cluster is available:

```bash
# 1. Confirm flannel VXLAN is active
kubectl get pods -n kube-system -l app=flannel -o wide
kubectl get nodes -o jsonpath='{.items[*].status.addresses}'

# 2. Identify the flannel VXLAN interface on each node
# (typically flannel.1 or flannel-vxlan; port is 8472)
ip -d link show flannel.1

# 3. Deploy traffic pods — one per node
kubectl apply -f k8s/traffic-pods.yaml
kubectl wait --for=condition=Ready pod -l app=vxlan-tracer-traffic --timeout=60s

# 4. Confirm cross-node pod-to-pod connectivity
POD_A=$(kubectl get pod -l app=vxlan-tracer-traffic -o jsonpath='{.items[0].metadata.name}')
POD_B=$(kubectl get pod -l app=vxlan-tracer-traffic -o jsonpath='{.items[1].metadata.name}')
kubectl exec "$POD_A" -- ping -c 3 $(kubectl get pod "$POD_B" -o jsonpath='{.status.podIP}')

# 5. Run vxlan-tracer on node 1 via node debug pod
# (requires root access to the node)
kubectl debug node/<node1> -it --image=ubuntu -- bash
# inside: nsenter -t 1 -m -u -i -n -- vxlan-tracer \
#   --overlay flannel.1 --underlay eth0 --duration 30s --json
```

---

## Expected baseline output

On a healthy k3s cluster with correct MTU:
- `verdict: NO_ISSUE_OBSERVED` or no MTU issue detected
- `vxlan_port: 8472` (flannel default)
- `ptb_ingress_total: 0`, `icmp_rcv_total: 0`, `frag_events_total: 0`

---

## NOT RUN

This baseline was not captured. No claims are made about k3s/flannel behavior.
See `docs/kubernetes-validation.md` for the full two-node validation checklist.
