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
// Priority 50000 is well above typical CNI tool priorities (Cilium: 1–10,
// Calico: 1), so vxlan-tracer filters run AFTER most CNI programs. This has an
// important implication for PTB observation: an earlier TC program that drops or
// modifies a PTB will prevent vxlan-tracer from observing it. PTB_SUPPRESSED
// means "not observed at vxlan-tracer's TC ingress hook" — it does NOT prove
// that the packet was suppressed by any specific earlier TC program.
//
// Handle major 0x7674 ('v','t' in ASCII) is the vxlan-tracer ownership marker.
// Handle minor 0x0001 is the instance sub-identifier. Together they form the
// full handle 0x7674_0001.
//
// Ownership verification during cleanup uses THREE fields simultaneously:
//   - priority == 50000
//   - full handle == 0x7674_0001
//   - kernel-assigned BPF program ID (stored at install time; re-checked at removal)
//
// Cleanup never deletes a filter unless all three match the stored identity.
const (
	vxlanTracerPriority    = 50000
	vxlanTracerHandleMajor = uint16(0x7674) // 'vt' in ASCII
	vxlanTracerHandleMinor = uint16(0x0001)
)

// vxlanTracerHandle is the complete TC filter handle (major<<16 | minor).
var vxlanTracerHandle = netlink.MakeHandle(vxlanTracerHandleMajor, vxlanTracerHandleMinor)

// lockPath is the exclusive run-lock. Only one invocation may run at a time.
const lockPath = "/run/vxlan-tracer.lock"

// ownedTCFilter records the exact kernel-reported identity of one TC filter
// installed by this Attachment. Close() re-verifies all fields before deleting.
type ownedTCFilter struct {
	ifaceIndex int    // interface index at install time
	ifaceName  string // interface name (for error messages)
	parent     uint32 // TC parent handle (HANDLE_MIN_INGRESS or HANDLE_MIN_EGRESS)
	handle     uint32 // full TC handle (major<<16 | minor)
	priority   uint16
	protocol   uint16
	filterName string // kernel-reported BPF program name (≤16 chars)
	progID     int    // kernel-assigned BPF program ID (TCA_BPF_ID); 0 if not reported
}

// Config describes which interfaces and compiled BPF objects to attach.
type Config struct {
	Overlay       string // VXLAN overlay interface, e.g. vxlan0
	Underlay      string // Underlay physical interface, e.g. eth0
	PinDir        string // bpffs directory for pinned maps
	TCIngressObj  string // compiled tc_ingress_eth0.bpf.o path
	TCEgressObj   string // compiled tc_egress_vxlan0.bpf.o path
	KprobeObj     string // compiled kprobes.bpf.o path
	FragKprobeObj string // compiled frag_kprobes.bpf.o path
	VXLANPort     uint16 // VXLAN UDP destination port in host byte order (0 = default 4789)
}

// Attachment holds everything attached by Attach, for deterministic cleanup
// via Close. Close removes exactly the resources recorded here; it never
// touches resources owned by other tools.
//
// Cleanup safety model:
//   - TC filters: re-list at cleanup time, verify handle+priority+name+progID,
//     delete only if all fields still match. Identity mismatch → warning, skip.
//   - clsact qdiscs: removed only if (a) we created them AND (b) no filters
//     remain after ours are removed.
//   - Maps: removed only if they appear in pinnedMapNames (our pinned set).
//   - Lock: released via LOCK_UN + close(fd).
type Attachment struct {
	ingressColl    *ebpf.Collection
	egressColl     *ebpf.Collection
	kprobeColl     *ebpf.Collection
	kprobeLink     link.Link
	fragKprobeColl *ebpf.Collection
	fragKprobeLink link.Link
	underlay       netlink.Link
	overlay        netlink.Link

	ownedFilters          []ownedTCFilter
	underlayClsactCreated bool
	overlayClsactCreated  bool
	pinDir                string
	lockFD                int
	closed                bool // set by Close(); prevents double-close from re-running cleanup
}

// pinnedMaps lists, per BPF object, which map names to pin under Config.PinDir.
var pinnedMaps = map[string][]string{
	"ingress":    {"ptb_ingress_counts", "ptb_ingress_total"},
	"egress":     {"flow_state"},
	"kprobe":     {"icmp_rcv_total"},
	"fragkprobe": {"frag_events_total"},
}

// pinnedMapNames is the complete list of map file names under PinDir.
// Close() removes each of these files.
var pinnedMapNames = []string{
	"ptb_ingress_counts",
	"ptb_ingress_total",
	"flow_state",
	"icmp_rcv_total",
	"frag_events_total",
}

// Attach loads the compiled BPF objects, attaches them to the configured
// interfaces / kernel functions, and pins their maps under cfg.PinDir.
//
// The Attachment struct is created immediately after acquiring the lock.
// Each mutation is recorded before the next operation, so a failure at any
// point causes Close() to clean up exactly what was already created —
// no more, no less. This includes partial clsact qdisc creation: if the
// underlay clsact is created but the overlay clsact setup fails, the underlay
// clsact is removed by the error path's Close() call.
//
// The TC slot (priority 50000, handle 0x7674_0001) must not be occupied before
// Attach is called. If it is, Attach returns a collision error without deleting
// the existing filter. Run 'vxlan-tracer cleanup' or remove manually first.
func Attach(cfg Config) (*Attachment, error) {
	lockFD, err := acquireLock()
	if err != nil {
		return nil, err
	}

	// Create the Attachment now so every subsequent mutation is tracked and
	// can be cleaned up via Close() on any error path below.
	a := &Attachment{
		pinDir: cfg.PinDir,
		lockFD: lockFD,
	}

	if cfg.PinDir != "" {
		if err := os.MkdirAll(cfg.PinDir, 0700); err != nil {
			a.Close()
			return nil, fmt.Errorf("create pin dir %q: %w", cfg.PinDir, err)
		}
	}

	underlay, err := netlink.LinkByName(cfg.Underlay)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("lookup underlay %q: %w", cfg.Underlay, err)
	}
	a.underlay = underlay

	overlay, err := netlink.LinkByName(cfg.Overlay)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("lookup overlay %q: %w", cfg.Overlay, err)
	}
	a.overlay = overlay

	// Record each clsact creation before proceeding. If overlay creation fails,
	// a.underlayClsactCreated is already true and Close() will clean it up.
	underlayCreated, err := ensureClsact(underlay)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("ensure clsact qdisc on underlay %q: %w", cfg.Underlay, err)
	}
	a.underlayClsactCreated = underlayCreated

	overlayCreated, err := ensureClsact(overlay)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("ensure clsact qdisc on overlay %q: %w", cfg.Overlay, err)
	}
	a.overlayClsactCreated = overlayCreated

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

// acquireLock opens and exclusively locks /run/vxlan-tracer.lock (LOCK_EX|LOCK_NB).
// Returns the open fd on success. The caller must release it via Close().
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
type vxlanCfgVal struct {
	VXLANDPort uint16
	Pad        uint16
}

// writeVXLANConfig writes the VXLAN UDP destination port into the vxlan_config
// ARRAY map in coll.
func writeVXLANConfig(coll *ebpf.Collection, portHost uint16) error {
	return writeVXLANPortToMaps(coll.Maps, portHost)
}

// writeVXLANPortToMaps is the testable core of writeVXLANConfig.
func writeVXLANPortToMaps(maps map[string]*ebpf.Map, portHost uint16) error {
	m, ok := maps["vxlan_config"]
	if !ok {
		return fmt.Errorf("vxlan_config map missing from tc_ingress object — " +
			"likely stale BPF object; run: make clean-bpf && make bpf")
	}
	if portHost == 0 {
		portHost = 4789
	}
	portNBO := (portHost >> 8) | (portHost << 8)
	key := uint32(0)
	val := vxlanCfgVal{VXLANDPort: portNBO}
	return m.Update(&key, &val, ebpf.UpdateAny)
}

// ensureClsact creates a clsact qdisc on l if one does not already exist.
// Returns (true, nil) if created, (false, nil) if pre-existing, (false, err) on failure.
func ensureClsact(l netlink.Link) (created bool, err error) {
	qdiscs, err := netlink.QdiscList(l)
	if err != nil {
		return false, fmt.Errorf("list qdiscs: %w", err)
	}
	for _, q := range qdiscs {
		if q.Type() == "clsact" {
			return false, nil
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
// under pinDir, and returns the collection and the named program.
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

// parentName returns "ingress" or "egress" for use in diagnostic messages.
func parentName(parent uint32) string {
	if parent == netlink.HANDLE_MIN_EGRESS {
		return "egress"
	}
	return "ingress"
}

// attachTC attaches prog as a direct-action TC BPF filter at the given
// clsact parent (HANDLE_MIN_INGRESS or HANDLE_MIN_EGRESS) on l.
//
// Safety rules:
//
//  1. COLLISION CHECK — if the reserved slot (priority 50000, handle 0x7674_0001)
//     is already occupied, this function returns an error without deleting the
//     existing filter. The caller must run 'vxlan-tracer cleanup' or remove it
//     manually.
//
//  2. INSTALL — calls FilterAdd with priority 50000, handle 0x7674_0001.
//
//  3. VERIFY — re-lists filters at the same parent to confirm the filter was
//     installed and to read the kernel-assigned BPF program ID. If the filter
//     cannot be found in the post-add list, it is deleted (safe rollback) and
//     an error is returned.
//
//  4. RECORD — stores the exact kernel-reported identity (handle, priority, name,
//     progID) in a.ownedFilters for verified cleanup in Close().
func (a *Attachment) attachTC(l netlink.Link, parent uint32, prog *ebpf.Program) error {
	dir := parentName(parent)

	// Phase 2: collision check — never delete an existing filter automatically.
	existing, err := netlink.FilterList(l, parent)
	if err == nil {
		for _, f := range existing {
			attrs := f.Attrs()
			if attrs.Handle == vxlanTracerHandle && attrs.Priority == vxlanTracerPriority {
				existingName := ""
				if bpf, ok := f.(*netlink.BpfFilter); ok {
					existingName = bpf.Name
				}
				return fmt.Errorf(
					"TC slot already occupied on %s %s "+
						"(prio %d handle 0x%08x name %q): "+
						"a vxlan-tracer filter is already installed. "+
						"Remove it with: tc filter del dev %s %s prio %d handle 0x%x bpf",
					l.Attrs().Name, dir,
					attrs.Priority, attrs.Handle, existingName,
					l.Attrs().Name, dir, vxlanTracerPriority, vxlanTracerHandle)
			}
		}
	}

	name := fmt.Sprintf("vt_%.13s", l.Attrs().Name) // 16-char kernel BPF name limit
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

	// Phase 3: re-list to get the kernel-assigned program ID for future ownership
	// verification. If the filter cannot be found, roll back and fail.
	installed, err := netlink.FilterList(l, parent)
	if err != nil {
		_ = netlink.FilterDel(filter)
		return fmt.Errorf("verify installed filter on %s %s: %w; rolled back", l.Attrs().Name, dir, err)
	}
	var progID int
	var found bool
	for _, f := range installed {
		attrs := f.Attrs()
		if attrs.Handle == vxlanTracerHandle && attrs.Priority == vxlanTracerPriority {
			if bpf, ok := f.(*netlink.BpfFilter); ok {
				progID = bpf.Id
			}
			found = true
			break
		}
	}
	if !found {
		_ = netlink.FilterDel(filter)
		return fmt.Errorf(
			"installed filter not found in post-add list on %s %s; rolled back",
			l.Attrs().Name, dir)
	}

	a.ownedFilters = append(a.ownedFilters, ownedTCFilter{
		ifaceIndex: l.Attrs().Index,
		ifaceName:  l.Attrs().Name,
		parent:     parent,
		handle:     vxlanTracerHandle,
		priority:   vxlanTracerPriority,
		protocol:   unix.ETH_P_ALL,
		filterName: name,
		progID:     progID,
	})
	return nil
}

// MTUs returns the current overlay and underlay interface MTUs (re-read at call
// time, not cached from Attach).
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

// Close performs deterministic cleanup. It is safe to call multiple times;
// calls after the first are no-ops (return nil).
//
// Cleanup order:
//  1. Kprobe links.
//  2. BPF collections (TC programs).
//  3. TC filters: re-list at each parent, verify handle+priority+name+progID,
//     delete only if all fields match. Identity mismatch → warning + error,
//     but cleanup of all other resources continues.
//  4. clsact qdiscs we created, if now empty.
//  5. Pinned map files and pin directory.
//  6. Run lock (LOCK_UN + close).
func (a *Attachment) Close() error {
	if a.closed {
		return nil
	}
	a.closed = true

	var firstErr error
	record := func(err error) {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	// 1. Kprobe links.
	if a.fragKprobeLink != nil {
		record(a.fragKprobeLink.Close())
		a.fragKprobeLink = nil
	}
	if a.fragKprobeColl != nil {
		a.fragKprobeColl.Close()
		a.fragKprobeColl = nil
	}
	if a.kprobeLink != nil {
		record(a.kprobeLink.Close())
		a.kprobeLink = nil
	}
	if a.kprobeColl != nil {
		a.kprobeColl.Close()
		a.kprobeColl = nil
	}

	// 2. BPF collections (TC programs).
	if a.egressColl != nil {
		a.egressColl.Close()
		a.egressColl = nil
	}
	if a.ingressColl != nil {
		a.ingressColl.Close()
		a.ingressColl = nil
	}

	// 3. TC filters: verify exact identity before deleting.
	for _, owned := range a.ownedFilters {
		record(removeVerifiedFilter(owned))
	}
	a.ownedFilters = nil

	// 4. clsact qdiscs we created, if now empty.
	if a.underlayClsactCreated && a.underlay != nil {
		maybeRemoveClsact(a.underlay)
		a.underlayClsactCreated = false
	}
	if a.overlayClsactCreated && a.overlay != nil {
		maybeRemoveClsact(a.overlay)
		a.overlayClsactCreated = false
	}

	// 5–6. Pinned maps and pin directory.
	if a.pinDir != "" {
		for _, name := range pinnedMapNames {
			_ = os.Remove(filepath.Join(a.pinDir, name))
		}
		_ = os.Remove(a.pinDir)
		a.pinDir = ""
	}

	// 7. Run lock.
	if a.lockFD >= 0 {
		_ = syscall.Flock(a.lockFD, syscall.LOCK_UN)
		_ = syscall.Close(a.lockFD)
		a.lockFD = -1
	}

	return firstErr
}

// removeVerifiedFilter re-lists filters at owned.parent and deletes the filter
// only if all identity fields (handle, priority, filterName, progID) still match
// what was recorded at installation. If the slot is empty or has a different
// filter, the function warns and returns without deleting.
func removeVerifiedFilter(owned ownedTCFilter) error {
	lnk, err := netlink.LinkByIndex(owned.ifaceIndex)
	if err != nil {
		// Interface was deleted; filter is gone with it.
		return nil
	}

	current, err := netlink.FilterList(lnk, owned.parent)
	if err != nil {
		return fmt.Errorf("list filters for cleanup on %s %s: %w",
			owned.ifaceName, parentName(owned.parent), err)
	}

	for _, f := range current {
		attrs := f.Attrs()
		if attrs.Handle != owned.handle || attrs.Priority != owned.priority {
			continue
		}
		// Found the slot. Verify identity before deleting.
		bpf, ok := f.(*netlink.BpfFilter)
		if !ok {
			fmt.Fprintf(os.Stderr,
				"warning: owned filter identity changed on %s %s "+
					"(slot has non-BPF filter); leaving current filter untouched\n",
				owned.ifaceName, parentName(owned.parent))
			return fmt.Errorf("owned filter identity changed on %s %s; leaving untouched",
				owned.ifaceName, parentName(owned.parent))
		}
		// Check name and progID. progID may be 0 if the kernel did not report it;
		// in that case we skip the progID check and rely on name + handle alone.
		nameMatch := bpf.Name == owned.filterName
		progMatch := owned.progID == 0 || bpf.Id == owned.progID
		if !nameMatch || !progMatch {
			fmt.Fprintf(os.Stderr,
				"warning: owned filter identity changed on %s %s "+
					"(installed progID=%d name=%q; current progID=%d name=%q); "+
					"leaving current filter untouched\n",
				owned.ifaceName, parentName(owned.parent),
				owned.progID, owned.filterName,
				bpf.Id, bpf.Name)
			return fmt.Errorf("owned filter identity changed on %s %s; leaving untouched",
				owned.ifaceName, parentName(owned.parent))
		}
		return netlink.FilterDel(f)
	}
	// Slot is empty — filter was already removed (e.g. by SIGKILL of a previous
	// run, or manual cleanup). This is not an error.
	return nil
}

// RemoveStaleFilters removes vxlan-tracer TC filters from the given interfaces.
// A filter is removed only if BOTH conditions match:
//   - priority == 50000 (vxlanTracerPriority)
//   - full handle == 0x7674_0001 (vxlanTracerHandle)
//
// This function does NOT run automatically. It is intended for use after a
// SIGKILL that left filters behind. It is NOT called during normal Attach/Close.
// If dryRun is true, matching filters are listed but not removed.
// Returns (removed, skipped, first error).
func RemoveStaleFilters(overlay, underlay string, dryRun bool) (removed, skipped int, firstErr error) {
	type entry struct {
		iface  string
		dir    string
		parent uint32
	}
	entries := []entry{
		{underlay, "ingress", netlink.HANDLE_MIN_INGRESS},
		{underlay, "egress", netlink.HANDLE_MIN_EGRESS},
		{overlay, "ingress", netlink.HANDLE_MIN_INGRESS},
		{overlay, "egress", netlink.HANDLE_MIN_EGRESS},
	}

	for _, e := range entries {
		if e.iface == "" {
			continue
		}
		lnk, err := netlink.LinkByName(e.iface)
		if err != nil {
			fmt.Fprintf(os.Stderr, "  %s %s: interface not found (%v)\n", e.iface, e.dir, err)
			skipped++
			continue
		}
		filters, err := netlink.FilterList(lnk, e.parent)
		if err != nil {
			fmt.Fprintf(os.Stderr, "  %s %s: list filters: %v\n", e.iface, e.dir, err)
			skipped++
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		found := false
		for _, f := range filters {
			attrs := f.Attrs()
			if attrs.Handle == vxlanTracerHandle && attrs.Priority == vxlanTracerPriority {
				found = true
				name := ""
				if bpf, ok := f.(*netlink.BpfFilter); ok {
					name = bpf.Name
				}
				if dryRun {
					fmt.Printf("  %s %s: would remove prio %d handle 0x%08x name %q\n",
						e.iface, e.dir, attrs.Priority, attrs.Handle, name)
					removed++
				} else {
					if err := netlink.FilterDel(f); err != nil {
						fmt.Fprintf(os.Stderr, "  %s %s: remove failed: %v\n", e.iface, e.dir, err)
						skipped++
						if firstErr == nil {
							firstErr = err
						}
					} else {
						fmt.Printf("  %s %s: removed prio %d handle 0x%08x name %q\n",
							e.iface, e.dir, attrs.Priority, attrs.Handle, name)
						removed++
					}
				}
				break
			}
		}
		if !found {
			fmt.Printf("  %s %s: no vxlan-tracer filter found\n", e.iface, e.dir)
		}
	}
	return removed, skipped, firstErr
}

// maybeRemoveClsact removes the clsact qdisc from l only if no filters remain
// on it (protects against removing a qdisc that another tool has populated).
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
