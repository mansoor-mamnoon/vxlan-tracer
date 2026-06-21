# 45-Second Demo Recording Plan

**Purpose:** Short screen recording for social posts, README, and outreach.
**Target length:** 45 seconds maximum (30 seconds of tool running, 15 seconds of setup/teardown).
**Format:** Terminal recording (asciinema or screen capture). No narration in first cut.

**Important:** The lab VXLAN interfaces (`vxlan0`, `demo-veth1`) live inside a network
namespace (`demo-ns1`). All commands that enumerate or diagnostic these interfaces must
run inside that namespace via `nsenter` or `ip netns exec`. The demo recording script
below handles this automatically.

---

## Scene breakdown

### Scene 1 — Interface discovery (0:00–0:08)

**Command (inside the lab namespace):**
```
$ sudo ip netns exec demo-ns1 \
    /path/to/vxlan-tracer interfaces
```

**Expected output:**
```
VXLAN interfaces on this host:

  NAME        VNI    PORT    MTU     UNDERLAY
  vxlan0      42     4789    1450    demo-veth1

Suggested invocations:
  sudo vxlan-tracer --overlay vxlan0 --underlay demo-veth1
```

**Why this first:** Shows the interface-discovery subcommand (no root token required
beyond the `ip netns exec` wrapper). Demonstrates read-only enumeration before any
BPF is loaded.

---

### Scene 2 — Run the diagnostic (0:08–0:40)

**Command (tracer inside the lab namespace):**
```
$ sudo ip netns exec demo-ns1 \
    /path/to/vxlan-tracer \
    --overlay vxlan0 \
    --underlay demo-veth1 \
    --bpf-dir /path/to/bpf \
    --duration 15s
```

**Expected stderr during run:**
```
vxlan-tracer v0.1.0-rc2
overlay:    vxlan0
underlay:   demo-veth1
vxlan port: 4789 (auto-detected)
vxlan vni:  42
pin dir:    /sys/fs/bpf/vxlan-tracer
bpf dir:    /path/to/bpf
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
cleanup: TC filters removed, maps unpinned, lock released
```

**Expected stdout verdict:**
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
  See docs/fragmentation-scoping.md for limitations.
```

**Traffic generation:** Start traffic BEFORE starting the tracer so that `ip_do_fragment`
fires during the 15-second window. The reproducible recording script (below) starts
traffic in a background loop and then launches the tracer.

---

### Scene 3 — JSON output (0:40–0:45)

**Command:**
```
$ sudo ip netns exec demo-ns1 \
    /path/to/vxlan-tracer \
    --overlay vxlan0 \
    --underlay demo-veth1 \
    --bpf-dir /path/to/bpf \
    --duration 5s \
    --json
```

**Expected output:**
```json
{"verdict":"VXLAN_FRAGMENTATION_OBSERVED","fragmentation_scope":"global_corroborated","overlay":"vxlan0","underlay":"demo-veth1","vxlan_port":4789,"vxlan_vni":42,"overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":0,"icmp_rcv_total":0,"frag_events_total":6,"frag_max_skb_len":1438,"max_outer_ip_len":1438}
```

---

## Reproducible recording script

This script sets up the lab, starts traffic, runs the tracer, and tears down.
Do not fake terminal output — run this verbatim.

```bash
#!/usr/bin/env bash
# demo-record.sh — reproducible lab setup and tracer run for demo recording.
# Run as root on a Linux host with compiled BPF objects and asciinema installed.
# Usage: sudo bash demo-record.sh [/path/to/vxlan-tracer] [/path/to/bpf]

set -euo pipefail

VT_BIN="${1:-./vxlan-tracer}"
BPF_DIR="${2:-bpf}"
NS="demo-ns1"

# ── Setup lab ──────────────────────────────────────────────────────────────
echo "[setup] creating network namespace ${NS}"
ip netns add "${NS}" 2>/dev/null || true

echo "[setup] creating veth pair"
ip link add demo-veth0 type veth peer name demo-veth1 2>/dev/null || true
ip link set demo-veth1 netns "${NS}"

ip netns exec "${NS}" ip link set lo up
ip netns exec "${NS}" ip link set demo-veth1 up
ip netns exec "${NS}" ip addr add 10.9.0.1/24 dev demo-veth1
ip link set demo-veth0 up
ip addr add 10.9.0.2/24 dev demo-veth0

echo "[setup] creating VXLAN interface inside ${NS}"
ip netns exec "${NS}" ip link add vxlan0 type vxlan \
    id 42 dstport 4789 dev demo-veth1
ip netns exec "${NS}" ip link set vxlan0 mtu 1450
ip netns exec "${NS}" ip link set vxlan0 up

echo "[setup] reducing underlay MTU to create fragmentation scenario"
ip netns exec "${NS}" ip link set demo-veth1 mtu 1400

echo "[setup] starting traffic (large pings in background)"
ip netns exec "${NS}" bash -c \
    'while true; do ping -c 1 -s 1400 -M do 10.9.0.2 &>/dev/null || true; sleep 1; done' &
TRAFFIC_PID=$!
trap 'kill ${TRAFFIC_PID} 2>/dev/null; ip netns del ${NS} 2>/dev/null; ip link del demo-veth0 2>/dev/null; true' EXIT

sleep 1  # let traffic flow before starting tracer

# ── Record with asciinema ──────────────────────────────────────────────────
echo "[record] starting asciinema recording"
asciinema rec demo.cast --overwrite --command "$(cat <<EOF
bash -c '
echo "";
echo "# Scene 1: discover VXLAN interfaces (no root token for enumeration)";
sleep 1;
sudo ip netns exec ${NS} ${VT_BIN} interfaces;
sleep 2;
echo "";
echo "# Scene 2: run diagnostic (15s window with live traffic)";
sleep 1;
sudo ip netns exec ${NS} ${VT_BIN} --overlay vxlan0 --underlay demo-veth1 --bpf-dir ${BPF_DIR} --duration 15s;
sleep 2;
echo "";
echo "# Scene 3: JSON output";
sleep 1;
sudo ip netns exec ${NS} ${VT_BIN} --overlay vxlan0 --underlay demo-veth1 --bpf-dir ${BPF_DIR} --duration 5s --json;
'
EOF
)"

echo "[done] recording saved to demo.cast"
echo "Review: asciinema play demo.cast"
echo "Export to GIF: agg demo.cast demo.gif"
```

---

## Recording tools

**Preferred:** `asciinema rec demo.cast` → `asciinema play demo.cast` for review
**For GIF:** `agg demo.cast demo.gif` (asciinema-agg)
**For video:** OBS Studio or screen capture

**Terminal font:** Monospace, 14pt or larger. JetBrains Mono, Fira Code, or Menlo.
**Terminal width:** 100 columns minimum.
**Color scheme:** Default dark background.

---

## What NOT to show

- Don't show the `make bpf` compilation step
- Don't show preflight.sh
- Don't show errors
- Don't fake terminal output — the script above produces real output from the real binary

---

## Captions (optional, for social post)

Frame 1 (0:00–0:08): "First: discover your VXLAN interfaces (enumeration only, no BPF loaded)"
Frame 2 (0:08–0:40): "Run the diagnostic on the overlay path (15s window with live traffic)"
Frame 3 (0:40–0:45): "Machine-readable JSON output for scripting"
Final frame: "vxlan-tracer v0.1.0-rc2 — github.com/mansoor-mamnoon/vxlan-tracer"
