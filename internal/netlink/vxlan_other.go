//go:build !linux

// Non-Linux stub. rtnetlink is a Linux-only facility; this file keeps
// go build ./... working on macOS.
package netlink

import "errors"

// VXLANInfo holds VXLAN link attributes used by vxlan-tracer.
type VXLANInfo struct {
	Port uint16
	VNI  uint32
}

// DetectVXLAN always fails on non-Linux platforms.
func DetectVXLAN(iface string) (VXLANInfo, error) {
	return VXLANInfo{}, errors.New("VXLAN auto-detection requires Linux")
}
