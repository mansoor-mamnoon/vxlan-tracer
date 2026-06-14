# docs/map-lifecycle.md

BPF map lifecycle, naming, and pinning for vxlan-tracer.

---

## Current approach (Day 3-4)

Maps are created on program load and destroyed when the program is unloaded or
the loader process exits. Map IDs are assigned by the kernel and are NOT stable
across load/reload cycles.

### How map IDs change

```sh
# First load
tc filter add dev veth1 ingress bpf da obj tc_ingress_eth0.bpf.o sec tc
# bpftool shows: ptb_ingress_cou id 77, ptb_ingress_tot id 78

# Reload (after kill and restart)
tc filter del dev veth1 ingress
tc filter add dev veth1 ingress bpf da obj tc_ingress_eth0.bpf.o sec tc
# bpftool shows: ptb_ingress_cou id 95, ptb_ingress_tot id 96  ← different!
```

For Day 3 and Day 4 evidence, map IDs were discovered at runtime via:
```sh
BPFTOOL map list | awk '/ptb_ingress_tot/{print $1}' | tr -d ':'
```

This works for interactive lab sessions but breaks across script runs.

---

## Problem: no stable map access path

The current state has three separate programs with three groups of maps:

| Program | Maps | Access |
|---------|------|--------|
| tc_ingress_eth0 | ptb_ingress_counts, ptb_ingress_total | bpftool by ID |
| tc_egress_vxlan0 | flow_state | bpftool by ID |
| kprobes (probe_attach) | icmp_rcv_total | bpftool by ID |

Each reload creates new maps with new IDs. The diagnose-from-bpftool.sh script
discovers IDs by name at runtime, which works but is fragile.

---

## Solution: map pinning under /sys/fs/bpf/vxlan-tracer/

BPF maps can be pinned to the BPF filesystem (bpffs, typically mounted at
`/sys/fs/bpf`). A pinned map persists as a filesystem entry and can be accessed
by path, surviving program reloads.

### Pinning plan for future Go loader

```
/sys/fs/bpf/vxlan-tracer/
  ptb_ingress_counts    ← pinned by tc_ingress_eth0 loader
  ptb_ingress_total     ← pinned by tc_ingress_eth0 loader
  flow_state            ← pinned by tc_egress_vxlan0 loader
  icmp_rcv_total        ← pinned by kprobe loader
```

The Go loader (cilium/ebpf) pins maps at load time:

```go
spec, _ := ebpf.LoadCollectionSpec("tc_ingress_eth0.bpf.o")
coll, _ := spec.LoadAndAssign(&objs, &ebpf.CollectionOptions{
    Maps: ebpf.MapOptions{
        PinPath: "/sys/fs/bpf/vxlan-tracer",
    },
})
```

A pinned map can then be accessed by any privileged process via path:
```sh
bpftool map dump pinned /sys/fs/bpf/vxlan-tracer/ptb_ingress_total
```

### Shared map across programs

The current architecture has each program create its own copies of maps.
For production, consider sharing ptb_ingress_counts between tc_ingress_eth0
and the reader (Go CLI), using pinned maps as the rendezvous point.

---

## Interaction between programs and map owners

When a TC program is reloaded (via `tc filter del/add`), the old maps are
released IF their reference count drops to zero. If the Go userspace reader
holds an fd to the pinned map (or has the map pinned in bpffs), the data
survives the program reload. This is the correct architecture for a daemon:

```
1. Go loader starts, loads all BPF programs, pins maps.
2. Programs attach (TC via tc filter, kprobe via bpf_link).
3. Go reader loop: open pinned maps, read periodically.
4. On reload: Go loader replaces programs but reuses existing pinned maps
   (via MapOptions.PinPath with LoadExisting).
5. On exit: bpf_link file descriptor is closed → kprobe detached.
   bpf_link can also be pinned to survive loader restart.
```

---

## Day 3-4 workaround vs. Day 5 target

| | Day 3-4 (current) | Day 5 (target) |
|--|-------------------|----------------|
| Map access | bpftool by live ID | Path under /sys/fs/bpf/vxlan-tracer/ |
| ID stability | Changes on reload | Stable (pinned) |
| Reader | scripts/diagnose-from-bpftool.sh | Go CLI (cmd/vxlan-tracer/) |
| Attach method | tc filter + probe_attach.c | Go loader with cilium/ebpf |
| Map sharing | Not shared (3 separate programs) | Shared via pinned bpffs paths |
| Cleanup on exit | TC filter survives; kprobe goes away with probe_attach | bpf_link pinned; survives reload |

---

## Note on bpftool map name disambiguation

bpftool truncates map names to 15 characters. The current names in the code:

| C map name | bpftool name |
|-----------|--------------|
| ptb_ingress_counts | ptb_ingress_cou |
| ptb_ingress_total | ptb_ingress_tot |
| flow_state | flow_state |
| icmp_rcv_total | icmp_rcv_total |

The diagnose-from-bpftool.sh script matches on the truncated name. For future
Go code, use the full map name (bpf_object__find_map_by_name uses the full BTF
name) or use pinned paths.
