# evidence/day-02-lab-setup.md

Lab topology setup results from Day 2.
Executed inside a Docker privileged container (linuxkit 6.10.14-linuxkit aarch64).

## Date: 2026-06-14

## Environment

| Item | Value |
|------|-------|
| Kernel | 6.10.14-linuxkit aarch64 |
| Container | ubuntu:22.04, --privileged |
| iproute2 | 5.15.0 |

## Setup approach

### Kernel MTU enforcement (finding from Day 2)

On kernel 6.10.14, setting vxlan0 MTU higher than `underlay_mtu - overhead` is rejected:

```
$ ip netns exec ns1 ip link set vxlan0 mtu 1500
RTNETLINK answers: Invalid argument
```

The kernel enforces the correct maximum. This prevents reproduction of the classic
Flannel misconfiguration (vxlan0 MTU=1500 with underlay=1500) on this kernel.

**Alternative topology used:**
1. Create vxlan0 while underlay MTU=1500 → kernel auto-sets vxlan0 MTU=1450 (correct).
2. Reduce underlay MTU to 1400 AFTER vxlan0 creation.
3. Kernel does NOT auto-adjust vxlan0 when underlay changes.
4. Result: vxlan0 MTU=1450 (stale), underlay=1400.
5. Max safe inner IP for underlay 1400: 1400 - 50 = 1350.
6. Inner IP > 1350 → outer IP > 1400 → ip_do_fragment fires (DF=0 default).

This models a real ops failure: underlay MTU changed without updating overlay MTU
(cloud provider changed MTU policy, or VPN appliance added to underlay path).

## Actual setup output

```
ns1 created
ns2 created
underlay veth pair up, MTU=1500

--- vxlan0 MTU after creation (should be 1450): ---
11: vxlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4e:bf:38:6b:af:b6 brd ff:ff:ff:ff:ff:ff
11: vxlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 86:da:7d:18:3e:61 brd ff:ff:ff:ff:ff:ff

--- underlay MTU reduced to 1400 (vxlan0 still at 1450): ---
13: veth1@if12: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 22:b2:e3:c6:17:71 brd ff:ff:ff:ff:ff:ff link-netns ns2
11: vxlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/ether 4e:bf:38:6b:af:b6 brd ff:ff:ff:ff:ff:ff
```

## MTU state after setup

| Interface | Namespace | MTU | Note |
|-----------|-----------|-----|------|
| veth1 | ns1 | 1400 | underlay (reduced after vxlan creation) |
| veth2 | ns2 | 1400 | underlay (reduced after vxlan creation) |
| vxlan0 | ns1 | 1450 | stale (was correct for underlay 1500; too high for 1400) |
| vxlan0 | ns2 | 1450 | stale |

## MTU arithmetic for this topology

```
VXLAN overhead:        50 bytes (inner ETH 14 + outer IP 20 + outer UDP 8 + VXLAN hdr 8)
Underlay MTU:          1400
Max safe inner IP:     1350 (underlay 1400 - overhead 50)
vxlan0 MTU (stale):    1450 → sends inner IP up to 1450

For small ping (payload 40B):
  inner IP = 68 bytes (ICMP: IP hdr 20 + ICMP hdr 8 + payload 40)
  outer IP = 68 + 50 = 118 bytes
  118 < 1400 → no fragmentation

For large ping (payload 1360B):
  inner IP = 1388 bytes (IP hdr 20 + ICMP hdr 8 + payload 1360)
  outer IP = 1388 + 50 = 1438 bytes
  1438 > 1400 → ip_do_fragment fires (DF=0 default on VXLAN)
```

## Reachability checks

```
--- small ping (safe: inner IP 68B, outer IP 118B): ---
PING 10.244.0.2 (10.244.0.2) 40(68) bytes of data.
--- 10.244.0.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2072ms
rtt min/avg/max/mdev = 0.055/0.132/0.230/0.072 ms
RESULT: PASS

--- large ping without DF set (inner IP 1388B → outer IP 1438B > 1400): ---
PING 10.244.0.2 (10.244.0.2) 1360(1388) bytes of data.
--- 10.244.0.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2039ms
rtt min/avg/max/mdev = 0.256/0.344/0.511/0.117 ms
RESULT: PASS (fragments reassemble — see note below)
```

**Note on large ping success:** With DF=0 (default on Linux VXLAN), oversized outer
packets are fragmented by ip_do_fragment. In a local veth+netns topology with no
middlebox, fragments are reassembled at the remote VTEP. This is why large pings
succeed. In production, cloud provider fabric or AWS/GCP/Azure VPC routing typically
drops VXLAN UDP fragments silently, causing the actual blackhole. See
docs/lab-topology.md for documentation on the fragmentation reassembly behavior.

## Scripts updated

`scripts/setup-netns.sh` was updated to use this alternative topology approach.
The original script attempted `ip link set vxlan0 mtu 1500` which fails on kernel 6.10+
with "RTNETLINK answers: Invalid argument".
