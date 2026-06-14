#!/usr/bin/env python3
"""
spikes/inject_ptb.py

SPIKE — not production code.

Inject a synthetic ICMP Packet Too Big (type=3 code=4) message into a network
namespace to test the PTB suppression detection path.

In production, ICMP PTBs arriving at a VXLAN underlay interface are generated
by routers or remote hosts in response to oversized outer packets with DF=1.
This script generates a synthetic PTB locally so that the suppression test
can be run without a real remote router.

The injected ICMP embeds a plausible outer IP + outer UDP (port 4789) header
in the ICMP payload, mimicking what a real router would send.

Usage:
    # From ns2, inject PTB toward ns1's underlay address
    ip netns exec ns2 python3 spikes/inject_ptb.py \\
        --src 192.168.100.2 \\
        --dst 192.168.100.1 \\
        --dev veth2 \\
        --next-hop-mtu 1400 \\
        --count 5

Prerequisites:
    pip3 install scapy
    Root / CAP_NET_RAW required
    Lab must be up: sudo make lab-up (or sudo bash scripts/setup-netns.sh)

Background:
    The vxlan-tracer PTB suppression detection works by comparing:
      - TC ingress count on underlay (pre-netfilter / pre-iptables)
      - icmp_rcv count (post-netfilter)
    If a PTB arrives at the underlay interface (TC count > 0) but is dropped
    by iptables before icmp_rcv (icmp_rcv count == 0), the delta reveals
    suppression. This script creates the synthetic PTB to trigger that path.

ICMP PTB structure:
    [outer ETH]
    [outer IP: src=192.168.100.2, dst=192.168.100.1, proto=ICMP]
    [ICMP type=3 code=4, next_hop_mtu=1400]
    [embedded original IP hdr: src=192.168.100.1, dst=192.168.100.2, proto=UDP]
    [embedded original UDP hdr: src_port=<random>, dst_port=4789 (VXLAN)]
"""

import argparse
import sys
import time

def main():
    parser = argparse.ArgumentParser(
        description="Inject synthetic ICMP PTB (type=3 code=4) for suppression testing"
    )
    parser.add_argument("--src", default="192.168.100.2",
                        help="Source IP of the synthetic PTB (usually the remote VTEP)")
    parser.add_argument("--dst", default="192.168.100.1",
                        help="Destination IP (the local VTEP that should receive the PTB)")
    parser.add_argument("--dev", default="veth2",
                        help="Network interface to send the packet on")
    parser.add_argument("--next-hop-mtu", type=int, default=1400,
                        help="Next-hop MTU to embed in the ICMP PTB (default: 1400)")
    parser.add_argument("--count", type=int, default=1,
                        help="Number of PTBs to inject (default: 1)")
    parser.add_argument("--interval", type=float, default=0.1,
                        help="Interval between packets in seconds (default: 0.1)")
    args = parser.parse_args()

    try:
        from scapy.all import (
            IP, ICMP, UDP, Ether, sendp, conf
        )
    except ImportError:
        print("ERROR: scapy not installed. Run: pip3 install scapy", file=sys.stderr)
        sys.exit(1)

    conf.verb = 0

    # Build the embedded original packet (what the oversized outer VXLAN packet
    # looked like; the ICMP PTB payload contains the first 8+ bytes of the
    # original IP header and the first 8 bytes of the transport header)
    original_ip = IP(
        src=args.dst,        # original outer src: the local VTEP
        dst=args.src,        # original outer dst: the remote VTEP
        proto=17,            # UDP
        len=1438,            # outer IP length that triggered PTB (inner 1388 + overhead 50)
        flags="DF",          # DF=1 set on outer IP
    )
    # VXLAN uses destination UDP port 4789
    original_udp = UDP(sport=12345, dport=4789)

    # Build the ICMP PTB
    icmp_ptb = ICMP(
        type=3,              # ICMP_DEST_UNREACH
        code=4,              # ICMP_FRAG_NEEDED
        unused=args.next_hop_mtu,  # scapy uses 'unused' field; for code=4, upper 16 bits = 0, lower = next_hop_mtu
    )

    # Outer IP carrying the ICMP
    outer_ip = IP(
        src=args.src,
        dst=args.dst,
        proto=1,             # ICMP
    )

    # Assemble: outer_ip / icmp_ptb / (embedded original_ip + original_udp)
    pkt = Ether() / outer_ip / icmp_ptb / original_ip / original_udp

    print(f"Injecting {args.count} synthetic ICMP PTB(s):")
    print(f"  src={args.src} → dst={args.dst}")
    print(f"  next_hop_mtu={args.next_hop_mtu}")
    print(f"  embedded: {args.dst}→{args.src} UDP dport=4789 (outer IP len=1438 DF=1)")
    print(f"  interface: {args.dev}")
    print()

    sent = 0
    for i in range(args.count):
        try:
            sendp(pkt, iface=args.dev, verbose=False)
            sent += 1
            if args.count > 1:
                print(f"  sent {i+1}/{args.count}")
            if i < args.count - 1:
                time.sleep(args.interval)
        except PermissionError:
            print("ERROR: Permission denied. Run as root or with CAP_NET_RAW.", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"\nDone. Sent {sent} ICMP PTB(s).")
    print()
    print("To verify PTB was received (before netfilter):")
    print("  Check TC ingress counter on the underlay interface in ns1.")
    print("  If iptables DROP rule is active in ns1 (icmptype 3 code 4),")
    print("  icmp_rcv count will be 0 but TC ingress count will be > 0.")
    print("  That delta is the suppression signal vxlan-tracer detects.")

if __name__ == "__main__":
    main()
