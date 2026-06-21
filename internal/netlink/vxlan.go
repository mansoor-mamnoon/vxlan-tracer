//go:build linux

// Package netlink provides helpers for reading VXLAN link attributes via rtnetlink.
package netlink

import (
	"fmt"

	"github.com/vishvananda/netlink"
)

// VXLANInfo holds the VXLAN link attributes that vxlan-tracer uses when
// auto-detecting the environment rather than relying on fixed defaults.
type VXLANInfo struct {
	Port uint16 // UDP destination port in host byte order (e.g. 4789, 8472)
	VNI  uint32 // VXLAN Network Identifier
}

// DetectVXLAN reads VXLAN link attributes for iface using rtnetlink.
// It returns an error if iface is not a VXLAN interface or cannot be queried;
// callers should warn and fall back to a default port rather than failing hard.
func DetectVXLAN(iface string) (VXLANInfo, error) {
	lnk, err := netlink.LinkByName(iface)
	if err != nil {
		return VXLANInfo{}, fmt.Errorf("lookup %q: %w", iface, err)
	}
	vx, ok := lnk.(*netlink.Vxlan)
	if !ok {
		return VXLANInfo{}, fmt.Errorf("%q is type %q, not vxlan", iface, lnk.Type())
	}
	port := uint16(vx.Port)
	if port == 0 {
		// The kernel returns 0 when the port was not explicitly configured;
		// the IANA-assigned VXLAN port 4789 is the implicit default.
		port = 4789
	}
	return VXLANInfo{
		Port: port,
		VNI:  uint32(vx.VxlanId),
	}, nil
}

// VXLANCandidate describes a VXLAN interface found on this host.
// It is returned by ListVXLAN and does not require root or BPF privileges.
type VXLANCandidate struct {
	Name     string `json:"name"`
	VNI      uint32 `json:"vni"`
	Port     uint16 `json:"port"`
	MTU      int    `json:"mtu"`
	Underlay string `json:"underlay,omitempty"` // inferred from VtepDevIndex; empty if not resolvable
}

// ListVXLAN returns all VXLAN-type interfaces on the host.
// It does not require root or BPF privileges on most kernels.
// Returns a non-nil empty slice (not an error) when no VXLAN interfaces are found.
func ListVXLAN() ([]VXLANCandidate, error) {
	links, err := netlink.LinkList()
	if err != nil {
		return nil, fmt.Errorf("list interfaces: %w", err)
	}
	out := make([]VXLANCandidate, 0)
	for _, lnk := range links {
		vx, ok := lnk.(*netlink.Vxlan)
		if !ok {
			continue
		}
		port := uint16(vx.Port)
		if port == 0 {
			port = 4789
		}
		c := VXLANCandidate{
			Name: lnk.Attrs().Name,
			VNI:  uint32(vx.VxlanId),
			Port: port,
			MTU:  lnk.Attrs().MTU,
		}
		if vx.VtepDevIndex != 0 {
			if under, err := netlink.LinkByIndex(vx.VtepDevIndex); err == nil {
				c.Underlay = under.Attrs().Name
			}
		}
		out = append(out, c)
	}
	return out, nil
}
