package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/mansoormmamnoon/vxlan-tracer/internal/loader"
)

const version = "0.1.0-dev"

func main() {
	overlay := flag.String("overlay", "", "VXLAN overlay interface (e.g. vxlan0)")
	underlay := flag.String("underlay", "", "Underlay physical interface (e.g. eth0)")
	vxlanPort := flag.Uint("vxlan-port", 4789, "VXLAN UDP destination port")
	pinDir := flag.String("pin-dir", "/sys/fs/bpf/vxlan-tracer", "bpffs directory to pin maps under (must exist; see scripts/setup-bpf-fs.sh)")
	bpfDir := flag.String("bpf-dir", "bpf", "directory containing compiled tc_ingress_eth0.bpf.o, tc_egress_vxlan0.bpf.o, kprobes.bpf.o")
	duration := flag.Duration("duration", 0, "Run for this long then exit (0 = run until interrupted)")
	jsonOut := flag.Bool("json", false, "Emit newline-delimited JSON instead of human-readable output")
	verbose := flag.Bool("v", false, "Print all flow events, not just findings")
	showVersion := flag.Bool("version", false, "Print version and exit")
	_ = vxlanPort
	_ = jsonOut
	_ = verbose

	flag.Parse()

	if *showVersion {
		fmt.Printf("vxlan-tracer %s\n", version)
		os.Exit(0)
	}

	if *overlay == "" || *underlay == "" {
		fmt.Fprintln(os.Stderr, "error: --overlay and --underlay are required")
		fmt.Fprintln(os.Stderr, "usage: vxlan-tracer --overlay <iface> --underlay <iface> [flags]")
		os.Exit(1)
	}

	cfg := loader.Config{
		Overlay:      *overlay,
		Underlay:     *underlay,
		PinDir:       *pinDir,
		TCIngressObj: filepath.Join(*bpfDir, "tc_ingress_eth0.bpf.o"),
		TCEgressObj:  filepath.Join(*bpfDir, "tc_egress_vxlan0.bpf.o"),
		KprobeObj:    filepath.Join(*bpfDir, "kprobes.bpf.o"),
	}

	fmt.Fprintf(os.Stderr, "vxlan-tracer %s\n", version)
	fmt.Fprintf(os.Stderr, "overlay:  %s\n", cfg.Overlay)
	fmt.Fprintf(os.Stderr, "underlay: %s\n", cfg.Underlay)
	fmt.Fprintf(os.Stderr, "pin dir:  %s\n", cfg.PinDir)
	fmt.Fprintf(os.Stderr, "bpf dir:  %s\n", *bpfDir)

	att, err := loader.Attach(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: attach failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "attached: tc ingress, tc egress, kprobe/icmp_rcv; maps pinned under "+cfg.PinDir)

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

	if err := att.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "warning: detach error: %v\n", err)
	}
	fmt.Fprintln(os.Stderr, "detached kprobe (TC filters remain attached; maps remain pinned)")
}
