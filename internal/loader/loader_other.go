//go:build !linux

// Non-Linux stub. BPF attachment requires Linux kernel facilities (netlink
// TC, kprobes, bpffs) that do not exist on other platforms. This keeps
// `go build ./...` and `go vet ./...` working on macOS, matching the rest
// of the project's "Go binary builds on any platform, BPF requires Linux"
// convention (see Makefile).
package loader

import "errors"

// Config mirrors the Linux Config so callers can build cfg literals on any
// platform; the fields are unused here.
type Config struct {
	Overlay      string
	Underlay     string
	PinDir       string
	TCIngressObj string
	TCEgressObj  string
	KprobeObj    string
}

// Attachment is an empty stand-in on non-Linux platforms.
type Attachment struct{}

// Attach always fails on non-Linux platforms.
func Attach(cfg Config) (*Attachment, error) {
	return nil, errors.New("vxlan-tracer loader: BPF attachment requires Linux")
}

// Close is a no-op on non-Linux platforms.
func (a *Attachment) Close() error { return nil }
