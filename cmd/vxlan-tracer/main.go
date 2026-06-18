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
	vxlanPort := flag.Uint("vxlan-port", 4789, "VXLAN UDP destination port")
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

	cfg := loader.Config{
		Overlay:       *overlay,
		Underlay:      *underlay,
		PinDir:        *pinDir,
		TCIngressObj:  filepath.Join(*bpfDir, "tc_ingress_eth0.bpf.o"),
		TCEgressObj:   filepath.Join(*bpfDir, "tc_egress_vxlan0.bpf.o"),
		KprobeObj:     filepath.Join(*bpfDir, "kprobes.bpf.o"),
		FragKprobeObj: filepath.Join(*bpfDir, "frag_kprobes.bpf.o"),
		VXLANPort:     uint16(*vxlanPort),
	}

	fmt.Fprintf(os.Stderr, "vxlan-tracer %s\n", version)
	fmt.Fprintf(os.Stderr, "overlay:    %s\n", cfg.Overlay)
	fmt.Fprintf(os.Stderr, "underlay:   %s\n", cfg.Underlay)
	fmt.Fprintf(os.Stderr, "vxlan port: %d\n", *vxlanPort)
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
		printJSON(verdict, obs, cfg.Overlay, cfg.Underlay)
	} else {
		fmt.Printf("verdict: %s\n", verdict.Verdict)
		fmt.Printf("%s\n", verdict.Message)
	}
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
func printJSON(verdict diag.Diagnosis, obs diag.Observation, overlayIface, underlayIface string) {
	r := jsonReport{
		Verdict:            string(verdict.Verdict),
		Message:            verdict.Message,
		FragmentationScope: string(verdict.FragmentationScope),
		Overlay:            overlayIface,
		Underlay:           underlayIface,
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
