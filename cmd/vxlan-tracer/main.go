package main

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap"
	"github.com/mansoormmamnoon/vxlan-tracer/internal/diag"
	"github.com/mansoormmamnoon/vxlan-tracer/internal/loader"
	inetlink "github.com/mansoormmamnoon/vxlan-tracer/internal/netlink"
)

// jsonReport is the structure emitted when --json is passed. Field names are
// snake_case to match common CLI/API conventions. All counter fields are
// unsigned ints so the consumer can reliably check > 0 without sign concerns.
// Fields with omitempty are omitted when zero (recommended_overlay_mtu when
// the config is already safe; frag_max_skb_len when no fragmentation was seen).
type jsonReport struct {
	Verdict               string `json:"verdict"`
	Message               string `json:"message"`
	FragmentationScope    string `json:"fragmentation_scope,omitempty"` // "global_corroborated" | "global_unscoped" | absent
	Overlay               string `json:"overlay"`
	Underlay              string `json:"underlay"`
	VXLANPort             uint16 `json:"vxlan_port,omitempty"` // effective VXLAN UDP dst port
	VXLANVNI              uint32 `json:"vxlan_vni,omitempty"`  // VNI from rtnetlink (0 if unknown)
	OverlayMTU            int    `json:"overlay_mtu"`
	UnderlayMTU           int    `json:"underlay_mtu"`
	RecommendedOverlayMTU int    `json:"recommended_overlay_mtu,omitempty"`
	PTBIngressTotal       uint64 `json:"ptb_ingress_total"`
	ICMPRcvTotal          uint64 `json:"icmp_rcv_total"`
	FragEventsTotal       uint64 `json:"frag_events_total"`
	FragMaxSKBLen         uint32 `json:"frag_max_skb_len,omitempty"`
	MaxOuterIPLen         int    `json:"max_outer_ip_len"`
}

// version, commit, and buildDate are set via -ldflags at build time.
// Defaults match an untagged local build.
var (
	version   = "dev"
	commit    = "none"
	buildDate = "unknown"
)

func main() {
	// Subcommand routing — check os.Args before flag.Parse() so subcommand
	// flags don't conflict with the main diagnostic flag set.
	if len(os.Args) >= 2 {
		switch os.Args[1] {
		case "interfaces":
			os.Exit(runInterfaces(os.Args[2:]))
		case "collect-support":
			os.Exit(runCollectSupport(os.Args[2:]))
		}
	}

	overlay := flag.String("overlay", "", "VXLAN overlay interface (e.g. vxlan0)")
	underlay := flag.String("underlay", "", "Underlay physical interface (e.g. eth0)")
	vxlanPort := flag.Uint("vxlan-port", 0, "VXLAN UDP destination port (0 = auto-detect from overlay interface)")
	pinDir := flag.String("pin-dir", "/sys/fs/bpf/vxlan-tracer", "bpffs directory to pin maps under (must exist; see scripts/setup-bpf-fs.sh)")
	bpfDir := flag.String("bpf-dir", "bpf", "directory containing compiled tc_ingress_eth0.bpf.o, tc_egress_vxlan0.bpf.o, kprobes.bpf.o")
	duration := flag.Duration("duration", 0, "Run for this long then exit (0 = run until SIGINT/SIGTERM)")
	jsonOut := flag.Bool("json", false, "Emit newline-delimited JSON instead of human-readable output")
	noClear := flag.Bool("no-clear", false, "Skip clearing pinned map counters at start of run (default: clear for fresh baseline)")
	keepState := flag.Bool("keep-state", false, "Skip TC filter and map cleanup on exit (unsafe on shared hosts; for lab/debug use only)")
	verbose := flag.Bool("v", false, "Print all flow events, not just findings")
	showVersion := flag.Bool("version", false, "Print version and exit")
	_ = verbose

	flag.Parse()

	if *showVersion {
		fmt.Printf("vxlan-tracer %s (commit %s, built %s)\n", version, commit, buildDate)
		os.Exit(0)
	}

	if *overlay == "" || *underlay == "" {
		fmt.Fprintln(os.Stderr, "error: --overlay and --underlay are required")
		fmt.Fprintln(os.Stderr, "usage: vxlan-tracer --overlay <iface> --underlay <iface> [flags]")
		os.Exit(2)
	}

	// Resolve VXLAN port and VNI.  When --vxlan-port is 0 (the default),
	// attempt to read them from the overlay interface via rtnetlink.  On
	// non-VXLAN interfaces (lab veth topology) or non-Linux builds the
	// detection will fail; fall back silently to 4789.
	var vxlanVNI uint32
	effectivePort := uint16(*vxlanPort)
	if effectivePort == 0 {
		info, err := inetlink.DetectVXLAN(*overlay)
		if err != nil {
			fmt.Fprintf(os.Stderr, "vxlan auto-detect: %v — using default port 4789\n", err)
			effectivePort = 4789
		} else {
			effectivePort = info.Port
			vxlanVNI = info.VNI
		}
	}

	cfg := loader.Config{
		Overlay:       *overlay,
		Underlay:      *underlay,
		PinDir:        *pinDir,
		TCIngressObj:  filepath.Join(*bpfDir, "tc_ingress_eth0.bpf.o"),
		TCEgressObj:   filepath.Join(*bpfDir, "tc_egress_vxlan0.bpf.o"),
		KprobeObj:     filepath.Join(*bpfDir, "kprobes.bpf.o"),
		FragKprobeObj: filepath.Join(*bpfDir, "frag_kprobes.bpf.o"),
		VXLANPort:     effectivePort,
	}

	fmt.Fprintf(os.Stderr, "vxlan-tracer %s\n", version)
	fmt.Fprintf(os.Stderr, "overlay:    %s\n", cfg.Overlay)
	fmt.Fprintf(os.Stderr, "underlay:   %s\n", cfg.Underlay)
	fmt.Fprintf(os.Stderr, "vxlan port: %d", effectivePort)
	if *vxlanPort == 0 {
		fmt.Fprintf(os.Stderr, " (auto-detected)")
	}
	fmt.Fprintln(os.Stderr)
	if vxlanVNI != 0 {
		fmt.Fprintf(os.Stderr, "vxlan vni:  %d\n", vxlanVNI)
	}
	fmt.Fprintf(os.Stderr, "pin dir:    %s\n", cfg.PinDir)
	fmt.Fprintf(os.Stderr, "bpf dir:    %s\n", *bpfDir)

	att, err := loader.Attach(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: attach failed: %v\n", err)
		os.Exit(2)
	}
	fmt.Fprintln(os.Stderr, "attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under "+cfg.PinDir)

	// Clear map counters so this run starts from a known-zero baseline.
	// Without this, stale counters from a prior run accumulate across reruns.
	if !*noClear {
		if err := bpfmap.ClearPinned(cfg.PinDir); err != nil {
			fmt.Fprintf(os.Stderr, "warning: map clear failed: %v\n", err)
		} else {
			fmt.Fprintln(os.Stderr, "maps cleared: fresh baseline for this run")
		}
	} else {
		fmt.Fprintln(os.Stderr, "maps NOT cleared (--no-clear): counters may include prior-run data")
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	if *duration > 0 {
		select {
		case <-time.After(*duration):
		case <-sigCh:
		}
	} else {
		<-sigCh
	}

	verdict, obs, diagErr := readVerdict(att, cfg.PinDir)

	if *keepState {
		fmt.Fprintln(os.Stderr, "cleanup: SKIPPED (--keep-state). TC filters and pinned maps remain.")
		fmt.Fprintln(os.Stderr, "  Remove TC filters manually:")
		fmt.Fprintf(os.Stderr, "    tc filter del dev %s ingress prio 50000\n", cfg.Underlay)
		fmt.Fprintf(os.Stderr, "    tc filter del dev %s egress  prio 50000\n", cfg.Overlay)
	} else {
		if err := att.Close(); err != nil {
			fmt.Fprintf(os.Stderr, "warning: cleanup error: %v\n", err)
		} else {
			fmt.Fprintln(os.Stderr, "cleanup: TC filters removed, maps unpinned, lock released")
		}
	}

	if diagErr != nil {
		fmt.Fprintf(os.Stderr, "error: diagnosis failed: %v\n", diagErr)
		os.Exit(2)
	}

	if *jsonOut {
		printJSON(verdict, obs, cfg.Overlay, cfg.Underlay, effectivePort, vxlanVNI)
	} else {
		printHuman(verdict, obs)
	}
}

// printHuman prints a structured human-readable diagnostic report.
// Sections: Verdict, Evidence, Recommendation (when applicable), Scope/Note.
// JSON output (--json flag) is handled separately by printJSON and is stable.
func printHuman(d diag.Diagnosis, obs diag.Observation) {
	fmt.Printf("\nVerdict:  %s\n", d.Verdict)

	switch d.Verdict {
	case diag.VerdictFragmentationObserved:
		fmt.Println("Evidence:")
		fmt.Printf("  ip_do_fragment events:   %d\n", obs.FragEventsTotal)
		if obs.MaxOuterIPLen > 0 {
			fmt.Printf("  largest outer IP seen:   %d B\n", obs.MaxOuterIPLen)
		}
		if obs.UnderlayMTU > 0 {
			fmt.Printf("  underlay MTU:            %d B", obs.UnderlayMTU)
			if obs.MaxOuterIPLen > obs.UnderlayMTU {
				fmt.Printf("  (outer packet exceeded by %d B)", obs.MaxOuterIPLen-obs.UnderlayMTU)
			}
			fmt.Println()
		}
		if obs.UnderlayMTU > 0 {
			fmt.Println("Recommendation:")
			fmt.Printf("  set overlay MTU to %d B or lower\n", obs.UnderlayMTU-diag.VXLANOverheadBytes)
			fmt.Println("  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)")
		}
		fmt.Println("Scope:")
		switch d.FragmentationScope {
		case diag.FragScopeGlobalCorroborated:
			fmt.Println("  global fragmentation counter corroborated by VXLAN TC egress")
			fmt.Println("  (both ip_do_fragment and oversized outer packets observed)")
		case diag.FragScopeGlobalUnscoped:
			fmt.Println("  global fragmentation counter — no VXLAN TC egress corroboration")
			fmt.Println("  (ip_do_fragment fires for all IP fragmentation on this host)")
		}
		fmt.Println("  See docs/fragmentation-scoping.md for limitations.")

	case diag.VerdictPTBDelivered:
		fmt.Println("Evidence:")
		fmt.Printf("  PTBs at TC ingress (pre-netfilter): %d\n", obs.PTBIngressTotal)
		fmt.Printf("  PTBs at icmp_rcv  (post-netfilter): %d  ← kernel received them\n", obs.ICMPRcvTotal)
		fmt.Println("Interpretation:")
		fmt.Println("  PTBs are not being suppressed. The kernel can act on them for PMTUD.")
		fmt.Println("  If large requests still fail, check that the application respects PTBs")
		fmt.Println("  and that the overlay MTU is correctly configured.")

	case diag.VerdictPTBSuppressed:
		fmt.Println("Evidence:")
		fmt.Printf("  PTBs at TC ingress (pre-netfilter): %d\n", obs.PTBIngressTotal)
		fmt.Printf("  PTBs at icmp_rcv  (post-netfilter): %d  ← dropped before kernel\n", obs.ICMPRcvTotal)
		fmt.Println("Recommendation:")
		fmt.Println("  PTBs are being dropped between the NIC and icmp_rcv.")
		fmt.Println("  Check:  iptables/nftables INPUT chain for ICMP type 3 code 4 DROP rules.")
		fmt.Println("  Fix:    allow ICMP fragmentation-needed (type 3 code 4) through your firewall.")

	case diag.VerdictMTUMisconfiguration:
		fmt.Println("Evidence:")
		if obs.OverlayMTU > 0 {
			fmt.Printf("  overlay MTU:   %d B (current)\n", obs.OverlayMTU)
		}
		if obs.UnderlayMTU > 0 {
			fmt.Printf("  underlay MTU:  %d B\n", obs.UnderlayMTU)
			safe := obs.UnderlayMTU - diag.VXLANOverheadBytes
			if obs.OverlayMTU > 0 && obs.OverlayMTU > safe {
				fmt.Printf("  excess:        %d B (overlay exceeds safe value by this much)\n", obs.OverlayMTU-safe)
			}
		}
		fmt.Println("Note:")
		fmt.Println("  No active fragmentation or PTBs observed — this is a static risk.")
		fmt.Println("  Traffic large enough to use the full overlay MTU will trigger fragmentation")
		fmt.Println("  or a PTB, depending on the DF bit.")
		if obs.UnderlayMTU > 0 {
			fmt.Println("Recommendation:")
			fmt.Printf("  set overlay MTU to %d B or lower\n", obs.UnderlayMTU-diag.VXLANOverheadBytes)
		}

	case diag.VerdictMTURisk:
		fmt.Println("Evidence:")
		fmt.Printf("  largest outer IP seen:  %d B\n", obs.MaxOuterIPLen)
		if obs.UnderlayMTU > 0 {
			fmt.Printf("  underlay MTU:           %d B (packet exceeded by %d B)\n",
				obs.UnderlayMTU, obs.MaxOuterIPLen-obs.UnderlayMTU)
		}
		fmt.Println("Note:")
		fmt.Println("  ip_do_fragment did not fire — packet may have been fragmented without")
		fmt.Println("  triggering the kprobe during this window, or DF=0 allowed silent fragmentation.")
		if obs.UnderlayMTU > 0 {
			fmt.Println("Recommendation:")
			fmt.Printf("  set overlay MTU to %d B or lower\n", obs.UnderlayMTU-diag.VXLANOverheadBytes)
		}

	default: // NO_ISSUE_OBSERVED
		fmt.Println("Evidence:")
		fmt.Println("  No PTBs, fragmentation events, or oversized traffic observed.")
		fmt.Println("Note:")
		fmt.Println("  This does not prove the path is healthy.")
		fmt.Println("  Run with larger traffic and a longer --duration for higher confidence.")
	}
	fmt.Println()
}

// readVerdict opens the pinned maps written by the loader, builds a
// diag.Observation from their current contents plus the live overlay/
// underlay MTUs, and returns the resulting diagnosis and the raw observation.
func readVerdict(att *loader.Attachment, pinDir string) (diag.Diagnosis, diag.Observation, error) {
	reader, err := bpfmap.OpenPinned(pinDir)
	if err != nil {
		return diag.Diagnosis{}, diag.Observation{}, fmt.Errorf("open pinned maps: %w", err)
	}
	defer reader.Close()

	ptbTotal, err := reader.PTBIngressTotal()
	if err != nil {
		return diag.Diagnosis{}, diag.Observation{}, fmt.Errorf("read ptb_ingress_total: %w", err)
	}
	icmpTotal, err := reader.ICMPRcvTotal()
	if err != nil {
		return diag.Diagnosis{}, diag.Observation{}, fmt.Errorf("read icmp_rcv_total: %w", err)
	}
	flows, err := reader.FlowState()
	if err != nil {
		return diag.Diagnosis{}, diag.Observation{}, fmt.Errorf("read flow_state: %w", err)
	}
	fragVal, err := reader.FragEventsTotal()
	if err != nil {
		return diag.Diagnosis{}, diag.Observation{}, fmt.Errorf("read frag_events_total: %w", err)
	}

	var maxOuterIPLen int
	for _, f := range flows {
		if int(f.Value.MaxOuterIPLen) > maxOuterIPLen {
			maxOuterIPLen = int(f.Value.MaxOuterIPLen)
		}
	}

	overlayMTU, underlayMTU, err := att.MTUs()
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not read interface MTUs: %v\n", err)
	}

	obs := diag.Observation{
		PTBIngressTotal: ptbTotal,
		ICMPRcvTotal:    icmpTotal,
		MaxOuterIPLen:   maxOuterIPLen,
		UnderlayMTU:     underlayMTU,
		OverlayMTU:      overlayMTU,
		FragEventsTotal: fragVal.Total,
		FragMaxSKBLen:   fragVal.MaxSKBLen,
	}
	return diag.Diagnose(obs), obs, nil
}

// runInterfaces implements "vxlan-tracer interfaces". It enumerates all
// VXLAN-type interfaces on the host and prints their VNI, port, MTU, and
// inferred underlay, plus suggested invocation lines for each. No root or
// BPF privileges are required.
func runInterfaces(args []string) int {
	fs := flag.NewFlagSet("interfaces", flag.ContinueOnError)
	jsonOut := fs.Bool("json", false, "Emit JSON array instead of human-readable output")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	candidates, err := inetlink.ListVXLAN()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		return 2
	}

	if *jsonOut {
		b, err := json.Marshal(candidates)
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: json marshal: %v\n", err)
			return 2
		}
		fmt.Printf("%s\n", b)
		return 0
	}

	if len(candidates) == 0 {
		fmt.Println("No VXLAN interfaces found on this host.")
		fmt.Println()
		fmt.Println("vxlan-tracer requires a VXLAN overlay interface.")
		fmt.Println("Common names: flannel.1 (k3s/Flannel), vxlan.calico (Calico), cilium_vxlan (Cilium), vxlan0 (manual)")
		fmt.Println()
		fmt.Println("If your overlay is in a different network namespace, re-run via nsenter.")
		return 0
	}

	fmt.Printf("VXLAN interfaces on this host:\n\n")
	fmt.Printf("  %-16s  %-6s  %-6s  %-6s  %s\n", "NAME", "VNI", "PORT", "MTU", "UNDERLAY")
	for _, c := range candidates {
		underlay := c.Underlay
		if underlay == "" {
			underlay = "(unknown)"
		}
		fmt.Printf("  %-16s  %-6d  %-6d  %-6d  %s\n", c.Name, c.VNI, c.Port, c.MTU, underlay)
	}
	fmt.Println()
	fmt.Println("Suggested invocations:")
	for _, c := range candidates {
		if c.Underlay != "" {
			fmt.Printf("  sudo vxlan-tracer --overlay %s --underlay %s\n", c.Name, c.Underlay)
		} else {
			fmt.Printf("  sudo vxlan-tracer --overlay %s --underlay <underlay-iface>\n", c.Name)
		}
	}
	return 0
}

// runCollectSupport implements "vxlan-tracer collect-support". It collects
// privacy-safe system diagnostic information into a tar.gz bundle suitable
// for attaching to a GitHub issue. No BPF privileges are required.
func runCollectSupport(args []string) int {
	fs := flag.NewFlagSet("collect-support", flag.ContinueOnError)
	dryRun := fs.Bool("dry-run", false, "Show what would be collected without creating a file")
	out := fs.String("out", "", "Output file path (default: vxlan-tracer-support-<timestamp>.tar.gz)")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	type item struct{ name, desc string }
	manifest := []item{
		{"system-info.txt", "Linux kernel version and architecture"},
		{"vxlan-interfaces.txt", "VXLAN interfaces: names, VNIs, ports, MTUs (no IP addresses)"},
		{"btf-status.txt", "BTF vmlinux file availability and size"},
		{"bpf-mounts.txt", "BPF filesystem mount entries from /proc/mounts"},
		{"kernel-symbols.txt", "ip_do_fragment and icmp_rcv symbol availability"},
		{"vxlan-tracer-version.txt", "vxlan-tracer version string"},
		{"CONTENTS.txt", "manifest of included files"},
		{"PRIVACY.txt", "privacy notice describing what is and is not included"},
	}

	if *dryRun {
		fmt.Println("Would collect (dry-run — nothing saved):")
		fmt.Println()
		for _, it := range manifest {
			fmt.Printf("  %-28s %s\n", it.name, it.desc)
		}
		fmt.Println()
		fmt.Println("Run without --dry-run to collect.")
		return 0
	}

	outPath := *out
	if outPath == "" {
		outPath = fmt.Sprintf("vxlan-tracer-support-%s.tar.gz", time.Now().Format("20060102-150405"))
	}

	files := make(map[string][]byte)
	fmt.Println("Collecting diagnostics...")

	// system-info.txt
	{
		var b strings.Builder
		if data, err := os.ReadFile("/proc/version"); err == nil {
			b.WriteString(strings.TrimSpace(string(data)) + "\n")
		} else {
			fmt.Fprintf(&b, "kernel: %v\n", err)
		}
		files["system-info.txt"] = []byte(b.String())
		fmt.Println("  [ok] system-info.txt")
	}

	// vxlan-interfaces.txt
	{
		var b strings.Builder
		candidates, err := inetlink.ListVXLAN()
		if err != nil {
			fmt.Fprintf(&b, "error: %v\n", err)
		} else if len(candidates) == 0 {
			b.WriteString("no VXLAN interfaces found\n")
		} else {
			fmt.Fprintf(&b, "%-16s  %-6s  %-6s  %-6s  %s\n", "NAME", "VNI", "PORT", "MTU", "UNDERLAY")
			for _, c := range candidates {
				under := c.Underlay
				if under == "" {
					under = "(unknown)"
				}
				fmt.Fprintf(&b, "%-16s  %-6d  %-6d  %-6d  %s\n", c.Name, c.VNI, c.Port, c.MTU, under)
			}
		}
		files["vxlan-interfaces.txt"] = []byte(b.String())
		fmt.Println("  [ok] vxlan-interfaces.txt")
	}

	// btf-status.txt
	{
		var b strings.Builder
		fi, err := os.Stat("/sys/kernel/btf/vmlinux")
		if err != nil {
			b.WriteString("/sys/kernel/btf/vmlinux: not found\n")
			b.WriteString("  CO-RE BPF programs will not load on this kernel.\n")
		} else {
			fmt.Fprintf(&b, "/sys/kernel/btf/vmlinux: present (%d bytes)\n", fi.Size())
		}
		files["btf-status.txt"] = []byte(b.String())
		fmt.Println("  [ok] btf-status.txt")
	}

	// bpf-mounts.txt
	{
		var b strings.Builder
		if data, err := os.ReadFile("/proc/mounts"); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.Contains(line, "bpf") {
					b.WriteString(line + "\n")
				}
			}
			if b.Len() == 0 {
				b.WriteString("no bpf mounts found in /proc/mounts\n")
			}
		} else {
			fmt.Fprintf(&b, "error reading /proc/mounts: %v\n", err)
		}
		files["bpf-mounts.txt"] = []byte(b.String())
		fmt.Println("  [ok] bpf-mounts.txt")
	}

	// kernel-symbols.txt — scan /proc/kallsyms for the two kprobe targets.
	// Only the presence/absence is recorded; the full symbol table is not included.
	{
		var b strings.Builder
		targets := map[string]bool{"ip_do_fragment": false, "icmp_rcv": false}
		f, err := os.Open("/proc/kallsyms")
		if err != nil {
			fmt.Fprintf(&b, "error reading /proc/kallsyms: %v\n", err)
			b.WriteString("  (may require root)\n")
		} else {
			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				fields := strings.Fields(scanner.Text())
				if len(fields) >= 3 && fields[1] == "T" {
					if _, want := targets[fields[2]]; want {
						targets[fields[2]] = true
					}
				}
			}
			f.Close()
			for sym, found := range targets {
				if found {
					fmt.Fprintf(&b, "%s: found (T symbol — kprobeable)\n", sym)
				} else {
					fmt.Fprintf(&b, "%s: NOT found as T symbol (may be inlined in this kernel)\n", sym)
				}
			}
		}
		files["kernel-symbols.txt"] = []byte(b.String())
		fmt.Println("  [ok] kernel-symbols.txt")
	}

	// vxlan-tracer-version.txt
	{
		files["vxlan-tracer-version.txt"] = []byte(
			fmt.Sprintf("vxlan-tracer %s (commit %s, built %s)\n", version, commit, buildDate),
		)
		fmt.Println("  [ok] vxlan-tracer-version.txt")
	}

	// CONTENTS.txt
	{
		var b strings.Builder
		fmt.Fprintf(&b, "vxlan-tracer support bundle\nCollected: %s\n\nFiles:\n\n", time.Now().Format(time.RFC3339))
		for _, it := range manifest {
			fmt.Fprintf(&b, "  %-28s %s\n", it.name, it.desc)
		}
		files["CONTENTS.txt"] = []byte(b.String())
		fmt.Println("  [ok] CONTENTS.txt")
	}

	// PRIVACY.txt
	files["PRIVACY.txt"] = []byte(supportBundlePrivacyNotice)
	fmt.Println("  [ok] PRIVACY.txt")

	// Write tar.gz
	fh, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: create %s: %v\n", outPath, err)
		return 2
	}
	gw := gzip.NewWriter(fh)
	tw := tar.NewWriter(gw)
	for name, content := range files {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0644, Size: int64(len(content))}); err != nil {
			fmt.Fprintf(os.Stderr, "error: tar header: %v\n", err)
			return 2
		}
		if _, err := tw.Write(content); err != nil {
			fmt.Fprintf(os.Stderr, "error: tar write: %v\n", err)
			return 2
		}
	}
	if err := tw.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "error: tar close: %v\n", err)
		return 2
	}
	if err := gw.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "error: gzip close: %v\n", err)
		return 2
	}
	if err := fh.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "error: file close: %v\n", err)
		return 2
	}

	fmt.Printf("\nBundle written: %s\n", outPath)
	fmt.Println("To share: attach this file to your GitHub issue.")
	return 0
}

const supportBundlePrivacyNotice = `PRIVACY NOTICE — vxlan-tracer collect-support bundle

INCLUDED
  - Linux kernel version and architecture (from /proc/version)
  - VXLAN interface names, VNIs, ports, and MTUs (no IP addresses)
  - Whether /sys/kernel/btf/vmlinux is present and its file size
  - BPF filesystem mount entries from /proc/mounts (device type + path only)
  - Whether ip_do_fragment and icmp_rcv are kprobeable symbols
    (presence indicator only — not the full /proc/kallsyms content)
  - vxlan-tracer version string

NOT INCLUDED
  - IP or MAC addresses of any interface
  - Route tables or routing policies
  - iptables, nftables, or other firewall rules
  - Running processes or their arguments
  - File system contents or paths
  - Credentials, tokens, secrets, or environment variables
  - Network traffic or packet payloads
  - Pod, container, or workload information
  - The full /proc/kallsyms symbol table
`

// printJSON emits a machine-readable JSON report on stdout. All diagnostic
// counters and MTU values from the observation window are included so
// consumers can derive their own logic without re-parsing human-readable text.
func printJSON(verdict diag.Diagnosis, obs diag.Observation, overlayIface, underlayIface string, vxlanPort uint16, vxlanVNI uint32) {
	r := jsonReport{
		Verdict:            string(verdict.Verdict),
		Message:            verdict.Message,
		FragmentationScope: string(verdict.FragmentationScope),
		Overlay:            overlayIface,
		Underlay:           underlayIface,
		VXLANPort:          vxlanPort,
		VXLANVNI:           vxlanVNI,
		OverlayMTU:         obs.OverlayMTU,
		UnderlayMTU:        obs.UnderlayMTU,
		PTBIngressTotal:    obs.PTBIngressTotal,
		ICMPRcvTotal:       obs.ICMPRcvTotal,
		FragEventsTotal:    obs.FragEventsTotal,
		FragMaxSKBLen:      obs.FragMaxSKBLen,
		MaxOuterIPLen:      obs.MaxOuterIPLen,
	}
	// Compute recommended_overlay_mtu when the current config is unsafe.
	if obs.UnderlayMTU > 0 && obs.OverlayMTU > 0 {
		check := diag.CheckMTU(obs.OverlayMTU, obs.UnderlayMTU)
		if !check.Correct {
			r.RecommendedOverlayMTU = obs.UnderlayMTU - diag.VXLANOverheadBytes
		}
	}
	b, err := json.Marshal(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: json marshal failed: %v\n", err)
		return
	}
	fmt.Printf("%s\n", b)
}
