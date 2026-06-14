# evidence/commands.md

Reference of exact commands needed to run the lab.
Updated as the project evolves.

## Environment check (run once per machine)

```sh
uname -a
go version
clang --version
bpftool version
grep -E " T ip_do_fragment$| T icmp_send$| T icmp_rcv$" /proc/kallsyms
ls /sys/kernel/btf/vmlinux
```

**Day 1 result on development machine (macOS):**
```
Darwin MacBook-Pro-880.local 25.0.0 Darwin Kernel Version 25.0.0 ... arm64
go version go1.26.3 darwin/arm64
Apple clang version 15.0.0 (clang-1500.3.9.4)
bpftool: not found
/proc/kallsyms: not available (macOS)
/sys/kernel/btf/vmlinux: not available (macOS)
```

All Linux-specific steps (netns, BPF, bpftrace) require a separate Linux host.
See: TARGET LINUX ENVIRONMENT below.

## Symbol availability check (run on target Linux host)

```sh
grep -E "^[0-9a-f]+ T ip_do_fragment$" /proc/kallsyms
grep -E "^[0-9a-f]+ T icmp_send$" /proc/kallsyms
grep -E "^[0-9a-f]+ T icmp_rcv$" /proc/kallsyms
grep -E "^[0-9a-f]+ T __ip_finish_output$" /proc/kallsyms
```

Expected on Linux 5.15 LTS:
```
ffffffff81a7c450 T ip_do_fragment
ffffffff81a8f2c0 T icmp_send
ffffffff81a8e930 T icmp_rcv
```

If `ip_do_fragment` is absent: inlined by compiler. Fall back to `__ip_finish_output`.

## Lab setup

```sh
# Requires Linux, root
sudo make lab-up
# or: sudo bash scripts/setup-netns.sh
```

## Lab verification after setup

```sh
# Verify namespaces exist
ip netns list

# Verify interfaces
ip netns exec ns1 ip link show
ip netns exec ns2 ip link show

# Check MTU values (vxlan0 should show 1500 — intentionally wrong)
ip netns exec ns1 ip link show vxlan0
ip netns exec ns2 ip link show vxlan0

# Verify VXLAN config
ip netns exec ns1 ip -d link show vxlan0

# Check DF bit (default: no 'df' flag = DF=0)
# With DF=0: ip -d link show vxlan0 | grep -v df
# With DF=1: ip link set vxlan0 type vxlan df set
```

## Smoke tests

```sh
# Small traffic (expected: PASS)
sudo make smoke-small
# or: sudo bash scripts/smoke-small-traffic.sh

# Large traffic (expected: fragmentation events; may or may not stall in local netns)
sudo make smoke-large
# or: sudo bash scripts/smoke-large-traffic.sh
```

## bpftrace probes

```sh
# Terminal 1: start probe
sudo bpftrace spikes/bpftrace/ip_do_fragment.bt

# Terminal 2: generate traffic
ip netns exec ns1 curl --max-time 30 http://10.244.0.2/large.bin -o /dev/null

# Expected output in Terminal 1:
# [ip_do_fragment] outer_len=1564 dev=veth1 dev_mtu=1500 excess=64
```

```sh
# PTB suppression test (requires df=set on vxlan0 AND iptables DROP rule)

# Step 1: reconfigure vxlan0 with df=set
ip netns exec ns1 ip link del vxlan0
ip netns exec ns1 ip link add vxlan0 type vxlan id 42 \
    remote 192.168.100.2 local 192.168.100.1 dstport 4789 dev veth1 df set
ip netns exec ns1 ip addr add 10.244.0.1/24 dev vxlan0
ip netns exec ns1 ip link set vxlan0 up mtu 1500

# Step 2: add suppression rule
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j DROP

# Step 3: start probe
sudo bpftrace spikes/bpftrace/ptb_suppression.bt

# Step 4: inject synthetic PTBs from ns2 via scapy (when available)
# ip netns exec ns2 python3 spikes/inject_ptb.py

# Step 5: remove suppression rule when done
ip netns exec ns1 iptables -D INPUT -p icmp --icmp-type fragmentation-needed -j DROP
```

## Lab teardown

```sh
sudo make lab-down
# or: sudo bash scripts/teardown-netns.sh
```

## Go tests (works on macOS)

```sh
go test ./...
go vet ./...
```

## MTU arithmetic manual verification

```
VXLAN overhead = 14 + 20 + 8 + 8 = 50 bytes
Safe vxlan0 MTU = 1500 - 50 = 1450
TCP MSS at vxlan0 MTU 1450 → inner IP 1450B → outer frame = 1450 + 14 + 50 = 1514B ≤ 1500 (fits)
TCP MSS at vxlan0 MTU 1500 → inner IP 1500B → outer frame = 1500 + 14 + 50 = 1564B > 1500 (fails)
```
