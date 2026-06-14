package main

import (
	"flag"
	"fmt"
	"os"
)

const version = "0.1.0-dev"

func main() {
	overlay := flag.String("overlay", "", "VXLAN overlay interface (e.g. vxlan0)")
	underlay := flag.String("underlay", "", "Underlay physical interface (e.g. eth0)")
	vxlanPort := flag.Uint("vxlan-port", 4789, "VXLAN UDP destination port")
	duration := flag.Duration("duration", 0, "Run for this long then exit (0 = run forever)")
	jsonOut := flag.Bool("json", false, "Emit newline-delimited JSON instead of human-readable output")
	verbose := flag.Bool("v", false, "Print all flow events, not just findings")
	showVersion := flag.Bool("version", false, "Print version and exit")
	_ = vxlanPort
	_ = duration
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

	fmt.Fprintf(os.Stderr, "vxlan-tracer %s (prototype — BPF attachment not yet implemented)\n", version)
	fmt.Fprintf(os.Stderr, "overlay:  %s\n", *overlay)
	fmt.Fprintf(os.Stderr, "underlay: %s\n", *underlay)
	fmt.Fprintln(os.Stderr, "See docs/architecture.md for implementation status.")
	os.Exit(1)
}
