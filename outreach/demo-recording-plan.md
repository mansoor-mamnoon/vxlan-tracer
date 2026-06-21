# 45-Second Demo Recording Plan

**Purpose:** Short screen recording for social posts, README, and outreach.
**Target length:** 45 seconds maximum (30 seconds of tool running, 15 seconds of setup/teardown).
**Format:** Terminal recording (asciinema or screen capture). No narration in first cut.

---

## Scene breakdown

### Scene 1 — Interface discovery (0:00–0:08)

**Command:**
```
$ vxlan-tracer interfaces
```

**Expected output:**
```
VXLAN interfaces on this host:

  NAME        VNI    PORT    MTU     UNDERLAY
  vxlan0      42     4789    1450    demo-veth1

Suggested invocations:
  sudo vxlan-tracer --overlay vxlan0 --underlay demo-veth1
```

**Why this first:** Shows the new subcommand that solves B1 from the audit. Demonstrates no-root read-only interface discovery before any BPF is loaded.

---

### Scene 2 — Run the diagnostic (0:08–0:40)

**Command (from packaged release archive):**
```
$ sudo ./vxlan-tracer --overlay vxlan0 --underlay demo-veth1 --duration 15s
```

**Expected stderr during run:**
```
vxlan-tracer v0.1.0-rc1
overlay:    vxlan0
underlay:   demo-veth1
vxlan port: 4789 (auto-detected)
vxlan vni:  42
pin dir:    /sys/fs/bpf/vxlan-tracer
bpf dir:    bpf
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
detached kprobes (TC filters remain attached; maps remain pinned)
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

**Scene note:** The 15-second window is enough for `scripts/demo.sh` to send 5 large pings during the tool's run. The demo should look like the diagnosis "just works" — the user runs one command and gets a clear verdict.

---

### Scene 3 — JSON output (0:40–0:45)

**Command:**
```
$ sudo ./vxlan-tracer --overlay vxlan0 --underlay demo-veth1 --duration 5s --json
```

**Expected output:**
```json
{"verdict":"VXLAN_FRAGMENTATION_OBSERVED","fragmentation_scope":"global_corroborated","overlay":"vxlan0","underlay":"demo-veth1","vxlan_port":4789,"vxlan_vni":42,"overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":0,"icmp_rcv_total":0,"frag_events_total":6,"frag_max_skb_len":1438,"max_outer_ip_len":1438}
```

---

## Recording setup (using demo.sh)

The recording should use a real environment, not a fake terminal. Use the provided demo script:

```sh
# From the packaged release archive:
cd vxlan-tracer-linux-amd64
sudo bash scripts/demo.sh
```

Or for a controlled split recording:

```sh
# Terminal 1: setup (run before recording)
sudo bash scripts/setup-netns.sh   # or equivalent from demo.sh setup section

# Terminal 2: record this session
vxlan-tracer interfaces              # scene 1
sudo ./vxlan-tracer --overlay vxlan0 --underlay demo-veth1 --duration 15s   # scene 2
sudo ./vxlan-tracer --overlay vxlan0 --underlay demo-veth1 --duration 5s --json   # scene 3
```

---

## Recording tools

**Preferred:** `asciinema rec demo.cast` → `asciinema play demo.cast` for review
**For GIF:** `agg demo.cast demo.gif` (asciinema-agg)
**For video:** OBS Studio or QuickTime screen capture

**Terminal font:** Use a monospace font at 14pt or larger. JetBrains Mono, Fira Code, or Menlo.
**Terminal width:** 100 columns minimum. The verdict output requires ~80 columns.
**Color scheme:** Default dark (black or dark gray background). The PASS/FAIL coloring from demo.sh is not needed here.

---

## What NOT to show

- Don't show the `make bpf` compilation step — too long, not relevant to the user path
- Don't show preflight.sh — too many checks for a 45-second demo
- Don't show errors — the demo should show the success path

---

## Captions (optional, for social post)

Frame 1 (0:00–0:08): "First: discover your VXLAN interfaces (no root needed)"
Frame 2 (0:08–0:40): "Run the diagnostic on the overlay path (15s window)"
Frame 3 (0:40–0:45): "Machine-readable JSON output for scripting"
Final frame: "vxlan-tracer v0.1.0-rc1 — github.com/mansoor-mamnoon/vxlan-tracer"
