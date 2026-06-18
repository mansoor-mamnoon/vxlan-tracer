// spikes/probe_helper/main.go
//
// Loads the compiled BPF probe programs and reports whether the verifier
// accepts them. Used to confirm bpf_get_netns_cookie availability for
// BPF_PROG_TYPE_KPROBE and BPF_PROG_TYPE_SCHED_CLS on the current kernel.
//
// Usage (inside Docker, after compiling BPF objects):
//   ./probe_helper --kprobe /tmp/probe_kprobe.bpf.o --cls /tmp/probe_cls.bpf.o
//
// Exit code: 0 if both load; 1 if either fails; 2 if only kprobe fails; 3 if only cls fails.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/cilium/ebpf"
)

func tryLoad(path, progType string) (ok bool) {
	spec, err := ebpf.LoadCollectionSpec(path)
	if err != nil {
		fmt.Printf("  [%s] LoadCollectionSpec failed: %v\n", progType, err)
		return false
	}

	// Find the first program in the spec
	var progSpec *ebpf.ProgramSpec
	var progName string
	for name, ps := range spec.Programs {
		progSpec = ps
		progName = name
		break
	}
	if progSpec == nil {
		fmt.Printf("  [%s] no programs in ELF\n", progType)
		return false
	}

	fmt.Printf("  [%s] loading program %q (section %q)\n", progType, progName, progSpec.SectionName)

	// Load with verbose verifier log on failure
	opts := &ebpf.CollectionOptions{
		Programs: ebpf.ProgramOptions{
			LogLevel: ebpf.LogLevelInstruction,
			LogSize:  1 << 20,
		},
	}

	coll, err := ebpf.NewCollectionWithOptions(spec, *opts)
	if err != nil {
		fmt.Printf("  [%s] FAILED: %v\n", progType, err)
		return false
	}
	defer coll.Close()

	fmt.Printf("  [%s] LOADED OK\n", progType)
	return true
}

func main() {
	kprobeObj := flag.String("kprobe", "/tmp/probe_kprobe.bpf.o", "kprobe BPF object")
	clsObj := flag.String("cls", "/tmp/probe_cls.bpf.o", "sched_cls BPF object")
	flag.Parse()

	fmt.Printf("Probing bpf_get_netns_cookie helper availability\n")
	fmt.Printf("Kernel: see uname -r\n\n")

	kprobeOK := tryLoad(*kprobeObj, "kprobe")
	fmt.Println()
	clsOK := tryLoad(*clsObj, "sched_cls")

	fmt.Printf("\n=== Summary ===\n")
	fmt.Printf("  kprobe bpf_get_netns_cookie: %s\n", supported(kprobeOK))
	fmt.Printf("  sched_cls bpf_get_netns_cookie: %s\n", supported(clsOK))

	if kprobeOK && clsOK {
		os.Exit(0)
	} else if !kprobeOK && !clsOK {
		os.Exit(1)
	} else if !kprobeOK {
		os.Exit(2)
	} else {
		os.Exit(3)
	}
}

func supported(ok bool) string {
	if ok {
		return "SUPPORTED"
	}
	return "UNSUPPORTED"
}
