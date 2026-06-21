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

// VXLANCandidate describes a VXLAN interface found on this host.
type VXLANCandidate struct {
	Name     string `json:"name"`
	VNI      uint32 `json:"vni"`
	Port     uint16 `json:"port"`
	MTU      int    `json:"mtu"`
	Underlay string `json:"underlay,omitempty"`
}

// ListVXLAN always returns an error on non-Linux platforms.
func ListVXLAN() ([]VXLANCandidate, error) {
	return nil, errors.New("VXLAN interface enumeration requires Linux")
}
