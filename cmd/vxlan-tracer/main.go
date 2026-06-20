package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
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

const version = "0.1.0-dev"

func main() {
	overlay := flag.String("overlay", "", "VXLAN overlay interface (e.g. vxlan0)")
	underlay := flag.String("underlay", "", "Underlay physical interface (e.g. eth0)")
	vxlanPort := flag.Uint("vxlan-port", 0, "VXLAN UDP destination port (0 = auto-detect from overlay interface)")
	pinDir := flag.String("pin-dir", "/sys/fs/bpf/vxlan-tracer", "bpffs directory to pin maps under (must exist; see scripts/setup-bpf-fs.sh)")
	bpfDir := flag.String("bpf-dir", "bpf", "directory containing compiled tc_ingress_eth0.bpf.o, tc_egress_vxlan0.bpf.o, kprobes.bpf.o")
	duration := flag.Duration("duration", 0, "Run for this long then exit (0 = run until SIGINT/SIGTERM)")
	jsonOut := flag.Bool("json", false, "Emit newline-delimited JSON instead of human-readable output")
	noClear := flag.Bool("no-clear", false, "Skip clearing pinned map counters at start of run (default: clear for fresh baseline)")
	verbose := flag.Bool("v", false, "Print all flow events, not just findings")
	showVersion := flag.Bool("version", false, "Print version and exit")
	_ = verbose

	flag.Parse()

	if *showVersion {
		fmt.Printf("vxlan-tracer %s\n", version)
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

	if err := att.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: detach error: %v\n", err)
	}
	fmt.Fprintln(os.Stderr, "detached kprobes (TC filters remain attached; maps remain pinned)")

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
