# Day 11 — Controlled MTU mismatch in a CNI environment

**Date:** 2026-06-18
**Goal:** Procedure for injecting a controlled MTU mismatch in a disposable
         k3s/Flannel cluster and observing vxlan-tracer's response.

**Status: NOT RUN** — no two-node k3s cluster is available for Day 11.
This document records the procedure for future execution.

---

## Prerequisites

- Two-node k3s cluster (see `docs/kubernetes-validation.md`)
- vxlan-tracer binary installed on both worker nodes
- `kubectl` access from a separate machine
- Root access on worker nodes via SSH

---

## Baseline (no fault)

Before injecting any fault, record the healthy baseline:

```bash
# On worker-node-1, run vxlan-tracer for 30s while cross-node pings run
ssh worker-node-1 sudo ./vxlan-tracer \
    --overlay flannel.1 --underlay eth0 \
    --duration 30s --json &

# Generate cross-node traffic (large packets, within overlay MTU)
POD_B_IP=$(kubectl -n vxlan-tracer-test get pod pod-b -o jsonpath='{.status.podIP}')
kubectl -n vxlan-tracer-test exec pod-a -- \
    ping -c 20 -s 1350 "$POD_B_IP"   # 1350 bytes < flannel overlay MTU 1450; no frag
```

Expected baseline verdict: `NO_ISSUE_OBSERVED` or `VXLAN_MTU_MISCONFIGURATION`
with `frag_events_total: 0` and `ptb_ingress_total: 0`.

The MTU chain on a healthy k3s/Flannel node:
- Underlay (eth0) MTU: 1500 (cloud VM default)
- Flannel overlay (flannel.1) MTU: 1450 = 1500 - 50
- Inner packet max safe size: 1450
- Outer IP max: 1500 (fits in underlay)
- Result: no fragmentation, no PTBs

---

## MTU fault injection (underlay reduction)

```bash
# Reduce underlay MTU on worker-node-1, creating: overlay 1450 > underlay 1400
ssh worker-node-1 sudo ip link set eth0 mtu 1400

# Verify fault: overlay still 1450, underlay now 1400
ssh worker-node-1 ip link show flannel.1   # MTU: 1450
ssh worker-node-1 ip link show eth0        # MTU: 1400

# Outer IP for a 1400-byte inner packet: 1400 + 50 = 1450 (ok)
# Outer IP for a 1450-byte inner packet: 1450 + 50 = 1500 (ok with new underlay = 1400? NO)
# Outer IP of 1400 > underlay MTU 1400? NO (1400 == 1400, at boundary)
# Outer IP of 1401 > underlay MTU 1400? YES → fragmentation
#
# Inner pkt size for frag: any inner > 1350 → outer > 1400 → ip_do_fragment fires
```

Run vxlan-tracer with fault active:

```bash
ssh worker-node-1 sudo ./vxlan-tracer \
    --overlay flannel.1 --underlay eth0 \
    --duration 30s --json &

# Generate oversized cross-node traffic
kubectl -n vxlan-tracer-test exec pod-a -- \
    ping -c 20 -s 1400 "$POD_B_IP"   # 1400-byte payload → outer IP ~1478 > 1400 → frag

wait
```

Expected verdict with flannel DF=0 (default):
```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "vxlan_port": 8472,
  "vxlan_vni": 1,
  "frag_events_total": <N>,
  "frag_max_skb_len": <M>,
  "max_outer_ip_len": <P>,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "fragmentation_scope": "global_corroborated"
}
```

NOTE: flannel uses DF=0 on the outer IP by default (same as lab vxlan0).
So the expected path is fragmentation, not PTB. To trigger PTBs in a CNI
environment, `DF=1` must be configured on the VXLAN interface — this is
non-default and not typically done in production.

---

## Expected clamping behavior

Cloud providers may block fragmented UDP packets (fragmented VXLAN) at the
virtual network layer. If the cloud provider drops fragments:
- The inner ping from pod-a to pod-b will stall (large pings fail)
- `frag_events_total` will be non-zero
- `ptb_ingress_total` will be 0 (DF=0 → no PTB generated)
- Verdict: `VXLAN_FRAGMENTATION_OBSERVED`

If the cloud provider reassembles fragments (unusual):
- Pings succeed despite fragmentation
- vxlan-tracer still reports fragmentation
- Verdict: `VXLAN_FRAGMENTATION_OBSERVED` with a note that fragments may
  reassemble in a lab/local env (this note is already in the verdict message)

---

## CNI MTU clamping: the correct overlay MTU case

Some CNI configurations or cloud providers clamp the overlay MTU correctly:
- flannel-node daemon sets flannel.1 MTU to `eth0 MTU - 50`
- After `ip link set eth0 mtu 1400`, flannel may automatically update
  flannel.1 MTU to 1350
- If so, outer IP ≤ 1400 → no fragmentation → `NO_ISSUE_OBSERVED`
- This is the CNI doing its job correctly

**Do not claim this as a tool failure.** The correct result when the CNI
has already corrected the MTU is `NO_ISSUE_OBSERVED`. Document the MTU
values actually observed, not what was expected.

---

## Cleanup

```bash
# Restore underlay MTU
ssh worker-node-1 sudo ip link set eth0 mtu 1500

# Flannel daemon should automatically restore overlay MTU to 1450
ssh worker-node-1 ip link show flannel.1   # expect: 1450

# Remove test pods
kubectl delete -f k8s/traffic-pods.yaml
kubectl delete -f k8s/namespace.yaml
```

---

## Evidence template

When this procedure is run, record:

```
Date:
Cluster: k3s <version>, <N> nodes
Worker node: <uname -a>
Underlay before fault: eth0 MTU <X>
Underlay after fault:  eth0 MTU <Y>
Overlay MTU observed:  flannel.1 MTU <Z>
VXLAN port confirmed:  <P> (from ip -d link show)
VNI confirmed:         <V>
vxlan-tracer verdict:  <JSON output>
Pod-a to pod-b ping result: <pass/fail, what size threshold>
```
