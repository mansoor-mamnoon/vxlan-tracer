# k8s/ — Kubernetes test manifests

Manifests for validating vxlan-tracer against a real Kubernetes CNI overlay.

## Requirements

- Two or more worker nodes (see `docs/kubernetes-validation.md`)
- A VXLAN-based CNI (Flannel, Calico VXLAN mode, Cilium VXLAN mode)
- kubectl configured to access the cluster
- vxlan-tracer binary compiled for the node's architecture

## Usage

```bash
# 1. Create test namespace and pods
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/traffic-pods.yaml

# 2. Verify pods are on different nodes (podAntiAffinity enforces this)
kubectl -n vxlan-tracer-test get pods -o wide

# 3. Find the VXLAN interface and port on a worker node
#    For k3s/Flannel (port 8472):
ssh worker-node-1 'ip -d link show flannel.1'

# 4. Run vxlan-tracer on the node that pod-a is scheduled on
#    (must be root; --vxlan-port 0 auto-detects from the overlay interface)
ssh worker-node-1 \
    sudo /path/to/vxlan-tracer \
    --overlay flannel.1 \
    --underlay eth0 \
    --duration 30s \
    --json

# 5. In another terminal, generate cross-node traffic
POD_B_IP=$(kubectl -n vxlan-tracer-test get pod pod-b -o jsonpath='{.status.podIP}')
kubectl -n vxlan-tracer-test exec -it pod-a -- \
    ping -c 20 -s 1400 "$POD_B_IP"

# 6. Examine the verdict and record evidence
```

## What to record

See `docs/kubernetes-validation.md` for the full proof checklist.
Evidence goes in `evidence/day-11-k8s-*.md`.

## Cleanup

```bash
kubectl delete -f k8s/traffic-pods.yaml
kubectl delete -f k8s/namespace.yaml
```
