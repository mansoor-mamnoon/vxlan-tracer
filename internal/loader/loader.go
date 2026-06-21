//go:build linux

// Package loader attaches the vxlan-tracer BPF programs (TC ingress on the
// underlay, TC egress on the VXLAN overlay, kprobe on icmp_rcv) and pins
// their maps under a bpffs directory.
//
// This package only builds on Linux: BPF program attachment requires Linux
// kernel facilities (netlink TC, kprobes, bpffs) that do not exist on other
// platforms. See loader_other.go for the non-Linux stub.
package loader

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

// TC filter identity for vxlan-tracer.
//
// Priority 50000 is chosen to be well above typical CNI tool priorities
// (Cilium: 1–10, Calico: 1, tc flower classifiers: 1–1000) so vxlan-tracer
// filters run last and never interfere with traffic forwarding. Running last
// does not affect correctness: all vxlan-tracer programs return TC_ACT_OK
// unconditionally, and PTBs/outer-packets are visible at any priority as long
// as no earlier filter returns TC_ACT_SHOT for them.
//
// Handle major 0x7674 ('v','t' in ASCII) is used as an ownership marker.
// Any filter at priority 50000 with this handle major was created by
// vxlan-tracer and may be safely deleted by vxlan-tracer during cleanup.
// Filters at any other priority or handle are never touched.
const (
	vxlanTracerPriority    = 50000
	vxlanTracerHandleMajor = uint16(0x7674) // 'vt' in ASCII
	vxlanTracerHandleMinor = uint16(0x0001)
)

// vxlanTracerHandle is the complete TC filter handle assigned to all
// vxlan-tracer filters. netlink.MakeHandle packs major<<16 | minor.
var vxlanTracerHandle = netlink.MakeHandle(vxlanTracerHandleMajor, vxlanTracerHandleMinor)

// lockPath is the exclusive run-lock for vxlan-tracer. Only one invocation
// may hold TC filters at a time; a second run fails with a clear error.
const lockPath = "/run/vxlan-tracer.lock"

// ownedTCFilter records one TC filter created by this Attachment.
type ownedTCFilter struct {
	link   netlink.Link
	parent uint32
}

// Config describes which interfaces and compiled BPF objects to attach.
type Config struct {
	Overlay       string // VXLAN overlay interface, e.g. vxlan0
	Underlay      string // Underlay physical interface, e.g. eth0
	PinDir        string // bpffs directory for pinned maps, e.g. /sys/fs/bpf/vxlan-tracer
	TCIngressObj  string // compiled tc_ingress_eth0.bpf.o path
	TCEgressObj   string // compiled tc_egress_vxlan0.bpf.o path
	KprobeObj     string // compiled kprobes.bpf.o path
	FragKprobeObj string // compiled frag_kprobes.bpf.o path (ip_do_fragment counter)
	VXLANPort     uint16 // VXLAN UDP destination port in host byte order (0 = default 4789)
}

// Attachment holds everything attached by Attach, for deterministic cleanup
// via Close. Close removes exactly the resources recorded here; it never
// touches resources created by other tools.
type Attachment struct {
	ingressColl    *ebpf.Collection
	egressColl     *ebpf.Collection
	kprobeColl     *ebpf.Collection
	kprobeLink     link.Link
	fragKprobeColl *ebpf.Collection
	fragKprobeLink link.Link
	underlay       netlink.Link
	overlay        netlink.Link

	// TC filters created by this invocation. Close() removes only these.
	ownedFilters []ownedTCFilter

	// clsact qdisc ownership. Close() removes a qdisc only if we created it
	// AND no filters remain on it after our own are removed.
	underlayClsactCreated bool
	overlayClsactCreated  bool

	// pinDir is the bpffs directory where maps are pinned. Close() unpins
	// all maps and removes the directory if it becomes empty.
	pinDir string

	// lockFD is the open file descriptor holding the exclusive run-lock.
	// Closed (releasing the lock) in Close().
	lockFD int
}

// pinnedMaps lists, per BPF object, which map names should be pinned under
// Config.PinDir. Maps not listed here are still created but not pinned.
var pinnedMaps = map[string][]string{
	"ingress":    {"ptb_ingress_counts", "ptb_ingress_total"},
	"egress":     {"flow_state"},
	"kprobe":     {"icmp_rcv_total"},
	"fragkprobe": {"frag_events_total"},
}

// pinnedMapNames is the complete list of map file names that may exist under
// PinDir after a successful attach. Close() removes each of these files.
var pinnedMapNames = []string{
	"ptb_ingress_counts",
	"ptb_ingress_total",
	"flow_state",
	"icmp_rcv_total",
	"frag_events_total",
}

// Attach loads the three compiled BPF objects, attaches them to the
// configured interfaces / kernel function, and pins their maps under
// cfg.PinDir. The TC clsact qdisc is created on each interface if missing.
//
// On failure, everything already attached in this call is torn down before
// returning the error (no half-attached state is left behind by a failed
// Attach call). Programs are pass-through (TC_ACT_OK) and the kprobe never
// affects packet delivery, so a failed attach has no traffic-path impact.
//
// Only one vxlan-tracer invocation may run at a time per host. Attach
// acquires /run/vxlan-tracer.lock before touching any kernel state and
// releases it in Close().
func Attach(cfg Config) (*Attachment, error) {
	lockFD, err := acquireLock()
	if err != nil {
		return nil, err
	}

	underlay, err := netlink.LinkByName(cfg.Underlay)
	if err != nil {
		_ = syscall.Close(lockFD)
		return nil, fmt.Errorf("lookup underlay %q: %w", cfg.Underlay, err)
	}
	overlay, err := netlink.LinkByName(cfg.Overlay)
	if err != nil {
		_ = syscall.Close(lockFD)
		return nil, fmt.Errorf("lookup overlay %q: %w", cfg.Overlay, err)
	}

	underlayCreated, err := ensureClsact(underlay)
	if err != nil {
		_ = syscall.Close(lockFD)
		return nil, fmt.Errorf("ensure clsact qdisc on underlay %q: %w", cfg.Underlay, err)
	}
	overlayCreated, err := ensureClsact(overlay)
	if err != nil {
		_ = syscall.Close(lockFD)
		return nil, fmt.Errorf("ensure clsact qdisc on overlay %q: %w", cfg.Overlay, err)
	}

	a := &Attachment{
		underlay:              underlay,
		overlay:               overlay,
		underlayClsactCreated: underlayCreated,
		overlayClsactCreated:  overlayCreated,
		pinDir:                cfg.PinDir,
		lockFD:                lockFD,
	}

	ingressColl, ingressProg, err := loadPinned(cfg.TCIngressObj, "tc_ingress_count_ptb", cfg.PinDir, pinnedMaps["ingress"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load tc ingress object %s: %w", cfg.TCIngressObj, err)
	}
	a.ingressColl = ingressColl
	if err := writeVXLANConfig(ingressColl, cfg.VXLANPort); err != nil {
		a.Close()
		return nil, fmt.Errorf("write vxlan config map: %w", err)
	}
	if err := a.attachTC(underlay, netlink.HANDLE_MIN_INGRESS, ingressProg); err != nil {
		a.Close()
		return nil, fmt.Errorf("attach tc ingress on %q: %w", cfg.Underlay, err)
	}

	egressColl, egressProg, err := loadPinned(cfg.TCEgressObj, "tc_egress_track_flow", cfg.PinDir, pinnedMaps["egress"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load tc egress object %s: %w", cfg.TCEgressObj, err)
	}
	a.egressColl = egressColl
	if err := a.attachTC(overlay, netlink.HANDLE_MIN_EGRESS, egressProg); err != nil {
		a.Close()
		return nil, fmt.Errorf("attach tc egress on %q: %w", cfg.Overlay, err)
	}

	kprobeColl, kprobeProg, err := loadPinned(cfg.KprobeObj, "kprobe_icmp_rcv", cfg.PinDir, pinnedMaps["kprobe"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load kprobe object %s: %w", cfg.KprobeObj, err)
	}
	a.kprobeColl = kprobeColl
	kp, err := link.Kprobe("icmp_rcv", kprobeProg, nil)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("attach kprobe icmp_rcv: %w", err)
	}
	a.kprobeLink = kp

	fragColl, fragProg, err := loadPinned(cfg.FragKprobeObj, "kprobe_ip_do_fragment", cfg.PinDir, pinnedMaps["fragkprobe"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load frag kprobe object %s: %w", cfg.FragKprobeObj, err)
	}
	a.fragKprobeColl = fragColl
	fkp, err := link.Kprobe("ip_do_fragment", fragProg, nil)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("attach kprobe ip_do_fragment: %w", err)
	}
	a.fragKprobeLink = fkp

	return a, nil
}

// acquireLock opens and exclusively locks /run/vxlan-tracer.lock using
// LOCK_EX|LOCK_NB. Returns the open fd on success. The caller must close
// the fd to release the lock.
func acquireLock() (int, error) {
	fd, err := syscall.Open(lockPath, syscall.O_CREAT|syscall.O_RDWR, 0600)
	if err != nil {
		return -1, fmt.Errorf("open lock file %s: %w", lockPath, err)
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		if err == syscall.EWOULDBLOCK {
			return -1, fmt.Errorf(
				"another vxlan-tracer invocation is already running (lock held by %s); "+
					"wait for it to exit or kill it first", lockPath)
		}
		return -1, fmt.Errorf("acquire lock %s: %w", lockPath, err)
	}
	return fd, nil
}

// vxlanCfgVal mirrors struct vxlan_cfg in bpf/maps.h.
// VXLANDPort must be in network byte order (big-endian) to match the
// __be16 field in the BPF struct that the TC program compares against
// udph->dest (which also arrives in NBO from the packet).
type vxlanCfgVal struct {
	VXLANDPort uint16
	Pad        uint16
}

// writeVXLANConfig writes the VXLAN UDP destination port into the vxlan_config
// ARRAY map in coll.  Fails hard if the map is absent — a missing map means the
// tc_ingress BPF object is stale (compiled before Day 11 added the map).  Stale
// objects silently fall back to port 4789 regardless of --vxlan-port, which would
// make the 8472 scenario pass for the wrong reason.
func writeVXLANConfig(coll *ebpf.Collection, portHost uint16) error {
	return writeVXLANPortToMaps(coll.Maps, portHost)
}

// writeVXLANPortToMaps is the testable core of writeVXLANConfig.
// It accepts the collection's Maps field directly so tests can supply an
// empty or partial map[string]*ebpf.Map without loading a real BPF object.
func writeVXLANPortToMaps(maps map[string]*ebpf.Map, portHost uint16) error {
	m, ok := maps["vxlan_config"]
	if !ok {
		return fmt.Errorf("vxlan_config map missing from tc_ingress object — " +
			"likely stale BPF object; run: make clean-bpf && make bpf")
	}
	if portHost == 0 {
		portHost = 4789
	}
	// Swap bytes: host-byte-order uint16 → network byte order uint16.
	// cilium/ebpf encodes structs in native (LE) byte order; storing portNBO
	// makes the encoded bytes match NBO, matching udph->dest in the packet.
	portNBO := (portHost >> 8) | (portHost << 8)
	key := uint32(0)
	val := vxlanCfgVal{VXLANDPort: portNBO}
	return m.Update(&key, &val, ebpf.UpdateAny)
}

// ensureClsact creates a clsact qdisc on l if one does not already exist.
// Returns (true, nil) if it created a new qdisc, (false, nil) if one was
// already present, or (false, err) on failure.
// clsact is required before TC BPF filters can be attached at ingress or
// egress.
func ensureClsact(l netlink.Link) (created bool, err error) {
	qdiscs, err := netlink.QdiscList(l)
	if err != nil {
		return false, fmt.Errorf("list qdiscs: %w", err)
	}
	for _, q := range qdiscs {
		if q.Type() == "clsact" {
			return false, nil // pre-existing; do not remove on cleanup
		}
	}
	if err := netlink.QdiscAdd(&netlink.GenericQdisc{
		QdiscAttrs: netlink.QdiscAttrs{
			LinkIndex: l.Attrs().Index,
			Handle:    netlink.MakeHandle(0xffff, 0),
			Parent:    netlink.HANDLE_CLSACT,
		},
		QdiscType: "clsact",
	}); err != nil {
		return false, err
	}
	return true, nil
}

// loadPinned loads the BPF object at objPath, marks pinNames for pinning
// under pinDir, creates the collection (which performs the pinning), and
// returns the collection along with the named program.
func loadPinned(objPath, progName, pinDir string, pinNames []string) (*ebpf.Collection, *ebpf.Program, error) {
	spec, err := ebpf.LoadCollectionSpec(objPath)
	if err != nil {
		return nil, nil, fmt.Errorf("load spec: %w", err)
	}
	for _, name := range pinNames {
		if m, ok := spec.Maps[name]; ok {
			m.Pinning = ebpf.PinByName
		}
	}
	coll, err := ebpf.NewCollectionWithOptions(spec, ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{PinPath: pinDir},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("new collection: %w", err)
	}
	prog, ok := coll.Programs[progName]
	if !ok {
		coll.Close()
		return nil, nil, fmt.Errorf("program %q not found in object", progName)
	}
	return coll, prog, nil
}

// attachTC attaches prog as a direct-action TC BPF filter at the given
// clsact parent (HANDLE_MIN_INGRESS or HANDLE_MIN_EGRESS) on l.
//
// Safety contract:
//   - Only filters at vxlanTracerPriority (50000) with vxlanTracerHandleMajor
//     (0x7674) are ever deleted. Filters at any other priority or handle are
//     never touched, regardless of which tool created them.
//   - The new filter is always installed at priority 50000, handle 0x7674_0001,
//     so it never occupies the priority ranges used by Cilium, Calico, or
//     operator-created classifiers.
//   - The created filter is recorded in a.ownedFilters so Close() can remove it.
func (a *Attachment) attachTC(l netlink.Link, parent uint32, prog *ebpf.Program) error {
	// Remove any previously installed vxlan-tracer filter at this parent
	// (left over from a prior run that was killed without cleanup). Only touch
	// filters whose priority AND handle major match our reserved values.
	if existing, err := netlink.FilterList(l, parent); err == nil {
		for _, f := range existing {
			attrs := f.Attrs()
			if attrs.Priority == vxlanTracerPriority &&
				uint16(attrs.Handle>>16) == vxlanTracerHandleMajor {
				_ = netlink.FilterDel(f)
			}
		}
	}

	name := fmt.Sprintf("vt_%.13s", l.Attrs().Name) // 16-char kernel BPF name limit: "vt_" + up to 13
	filter := &netlink.BpfFilter{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: l.Attrs().Index,
			Parent:    parent,
			Handle:    vxlanTracerHandle,
			Protocol:  unix.ETH_P_ALL,
			Priority:  vxlanTracerPriority,
		},
		Fd:           prog.FD(),
		Name:         name,
		DirectAction: true,
	}
	if err := netlink.FilterAdd(filter); err != nil {
		return err
	}
	a.ownedFilters = append(a.ownedFilters, ownedTCFilter{link: l, parent: parent})
	return nil
}

// MTUs returns the current overlay and underlay interface MTUs, re-read at
// call time (not cached from Attach), so callers see any change made after
// attachment (e.g. a stale overlay MTU left over from before the underlay
// MTU was reduced — the scenario this tool exists to diagnose).
func (a *Attachment) MTUs() (overlayMTU, underlayMTU int, err error) {
	u, err := netlink.LinkByIndex(a.underlay.Attrs().Index)
	if err != nil {
		return 0, 0, fmt.Errorf("re-read underlay MTU: %w", err)
	}
	o, err := netlink.LinkByIndex(a.overlay.Attrs().Index)
	if err != nil {
		return 0, 0, fmt.Errorf("re-read overlay MTU: %w", err)
	}
	return o.Attrs().MTU, u.Attrs().MTU, nil
}

// Close performs deterministic cleanup in this order:
//  1. Kprobe links (die when FD closes; no persistence).
//  2. BPF collections (program and map FDs).
//  3. TC filters created by this invocation (identified by priority 50000 +
//     handle major 0x7674). Filters at any other priority are never touched.
//  4. clsact qdiscs, but only if (a) we created them AND (b) no remaining
//     filters exist on the qdisc after our own are removed.
//  5. Pinned map files under pinDir.
//  6. Pin directory, if now empty.
//  7. Run lock.
//
// Close is safe to call on a partially-initialised Attachment (nil checks
// throughout). It collects and returns the first error encountered without
// stopping; all cleanup steps run regardless.
func (a *Attachment) Close() error {
	var firstErr error

	record := func(err error) {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	// 1. Kprobe links.
	if a.fragKprobeLink != nil {
		record(a.fragKprobeLink.Close())
	}
	if a.fragKprobeColl != nil {
		a.fragKprobeColl.Close()
	}
	if a.kprobeLink != nil {
		record(a.kprobeLink.Close())
	}
	if a.kprobeColl != nil {
		a.kprobeColl.Close()
	}

	// 2. BPF collections (TC programs).
	if a.egressColl != nil {
		a.egressColl.Close()
	}
	if a.ingressColl != nil {
		a.ingressColl.Close()
	}

	// 3. TC filters owned by this invocation.
	for _, f := range a.ownedFilters {
		filter := &netlink.BpfFilter{
			FilterAttrs: netlink.FilterAttrs{
				LinkIndex: f.link.Attrs().Index,
				Parent:    f.parent,
				Handle:    vxlanTracerHandle,
				Protocol:  unix.ETH_P_ALL,
				Priority:  vxlanTracerPriority,
			},
		}
		record(netlink.FilterDel(filter))
	}

	// 4. clsact qdiscs we created, if now empty.
	if a.underlayClsactCreated && a.underlay != nil {
		maybeRemoveClsact(a.underlay)
	}
	if a.overlayClsactCreated && a.overlay != nil {
		maybeRemoveClsact(a.overlay)
	}

	// 5–6. Pinned maps and pin directory.
	if a.pinDir != "" {
		for _, name := range pinnedMapNames {
			_ = os.Remove(filepath.Join(a.pinDir, name))
		}
		_ = os.Remove(a.pinDir) // succeeds only if directory is now empty
	}

	// 7. Run lock.
	if a.lockFD >= 0 {
		_ = syscall.Flock(a.lockFD, syscall.LOCK_UN)
		_ = syscall.Close(a.lockFD)
		a.lockFD = -1
	}

	return firstErr
}

// maybeRemoveClsact removes the clsact qdisc from l only if no filters remain
// on it. This avoids removing a qdisc that another tool has added filters to
// during our run.
func maybeRemoveClsact(l netlink.Link) {
	ingress, _ := netlink.FilterList(l, netlink.HANDLE_MIN_INGRESS)
	egress, _ := netlink.FilterList(l, netlink.HANDLE_MIN_EGRESS)
	if len(ingress) > 0 || len(egress) > 0 {
		return
	}
	_ = netlink.QdiscDel(&netlink.GenericQdisc{
		QdiscAttrs: netlink.QdiscAttrs{
			LinkIndex: l.Attrs().Index,
			Handle:    netlink.MakeHandle(0xffff, 0),
			Parent:    netlink.HANDLE_CLSACT,
		},
		QdiscType: "clsact",
	})
}
