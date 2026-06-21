# GSO/GRO Live Test Results — rc2 Evidence

**Status:** NOT RUN
**Gate:** All GSO/GRO outreach (PC06 class, Calico GRO/GSO issues) blocked until PASS

---

## Required tests

See `docs/gso-gro-limitations.md` for the full test design.

| Test | Status |
|------|--------|
| GSO on: observe `max_outer_ip_len` vs actual wire frame size | NOT RUN |
| GSO off: compare `max_outer_ip_len` to wire captures | NOT RUN |
| GRO on/off: PTB count affected? | NOT RUN |
| ip_do_fragment with GSO on: does it fire correctly? | NOT RUN |

---

## Why this matters

Until these tests run, the following claims must be treated as UNVERIFIED:
- "`VXLAN_FRAGMENTATION_OBSERVED` is not affected by GSO"
- "`PTB_SUPPRESSED` / `PTB_DELIVERED` are not affected by GRO"
- "`VXLAN_MTU_RISK` is the only verdict affected by GSO"

See `docs/forbidden-claims.md` section 18 for forbidden phrasing.

---

## How to run

On a Linux host (kernel ≥ 5.15, root, compiled BPF objects, `ethtool`, `tcpdump`):

```bash
# Setup
sudo bash scripts/setup-netns.sh

# Test 1: GSO on (default) — TCP traffic
sudo ip netns exec demo-ns1 iperf3 -c <server-ip> -t 10 &
sudo vxlan-tracer --overlay vxlan0 --underlay veth0 --duration 10s --json > /tmp/gso-on.json
ethtool -k vxlan0 | grep segmentation
# Record: max_outer_ip_len in JSON vs wire captures

# Test 2: GSO off
sudo ethtool -K vxlan0 tx off
sudo ip netns exec demo-ns1 iperf3 -c <server-ip> -t 10 &
sudo vxlan-tracer --overlay vxlan0 --underlay veth0 --duration 10s --json > /tmp/gso-off.json
# Record: max_outer_ip_len in JSON vs wire captures

# Test 3: GRO + PTB injection
sudo bash scripts/inject_ptb.py &
sudo vxlan-tracer --overlay vxlan0 --underlay veth0 --duration 10s --json > /tmp/gro-ptb.json
ethtool -k veth0 | grep receive-offload
# Record: ptb_ingress_total with GRO on vs off

# Compare
jq '{max_outer_ip_len, ptb_ingress_total, frag_events_total, verdict}' /tmp/gso-on.json /tmp/gso-off.json
```

---

## Results placeholder

```
[NO OUTPUT — tests not yet run]
```

Results must be recorded here verbatim before any GSO/GRO outreach is sent.
