// spikes/probe_frag_scope/main.go
//
// Loads probe_frag_scope.bpf.o, attaches it to ip_do_fragment, and reads
// back the scope result map after a test event. Used to test whether
// bpf_probe_read_kernel-based skb header parsing works at ip_do_fragment entry.
//
// Usage (inside Docker, after compiling the BPF object):
//   ./probe_frag_scope --obj /tmp/probe_frag_scope.bpf.o --duration 30s
//
// The binary attaches the kprobe, waits for duration, then prints the map contents.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
)

func main() {
	objPath := flag.String("obj", "/tmp/probe_frag_scope.bpf.o", "BPF object file")
	duration := flag.Duration("duration", 15*time.Second, "observation window")
	flag.Parse()

	spec, err := ebpf.LoadCollectionSpec(*objPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "LoadCollectionSpec: %v\n", err)
		os.Exit(2)
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, ebpf.CollectionOptions{
		Programs: ebpf.ProgramOptions{
			LogLevel: ebpf.LogLevelInstruction,
			LogSize:  1 << 20,
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "NewCollection: %v\n", err)
		os.Exit(2)
	}
	defer coll.Close()

	prog := coll.Programs["probe_frag_scope"]
	if prog == nil {
		fmt.Fprintf(os.Stderr, "program probe_frag_scope not found in collection\n")
		os.Exit(2)
	}

	kp, err := link.Kprobe("ip_do_fragment", prog, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Kprobe attach: %v\n", err)
		os.Exit(2)
	}
	defer kp.Close()

	fmt.Printf("attached kprobe/ip_do_fragment — waiting %s for fragmentation events\n", *duration)
	fmt.Printf("send large VXLAN traffic from ns1 to trigger ip_do_fragment\n")
	time.Sleep(*duration)

	// Read result map
	resultMap := coll.Maps["frag_scope_result"]
	vxlanMap := coll.Maps["frag_vxlan_count"]

	if resultMap == nil || vxlanMap == nil {
		fmt.Fprintf(os.Stderr, "maps not found\n")
		os.Exit(2)
	}

	fields := []string{"skb_len", "ip_proto", "udp_dport", "is_vxlan"}
	fmt.Printf("\nfrag_scope_result map:\n")
	for i, name := range fields {
		var key uint32 = uint32(i)
		var val uint64
		if err := resultMap.Lookup(&key, &val); err != nil {
			fmt.Printf("  [%d] %s: (empty)\n", i, name)
		} else {
			fmt.Printf("  [%d] %s: %d (0x%04x)\n", i, name, val, val)
		}
	}

	var zeroKey uint32
	var vxlanCount uint64
	if err := vxlanMap.Lookup(&zeroKey, &vxlanCount); err == nil {
		fmt.Printf("\nfrag_vxlan_count: %d\n", vxlanCount)
	}

	fmt.Printf("\nInterpretation:\n")
	fmt.Printf("  ip_proto=17 (0x11) → UDP (expected for VXLAN outer)\n")
	fmt.Printf("  udp_dport=4789 (0x12b5) → VXLAN port (expected)\n")
	fmt.Printf("  is_vxlan=1 → scoped VXLAN fragmentation counter incremented\n")
}
