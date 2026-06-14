# evidence/day-04-unsuppressed.md

Unsuppressed ICMP PTB path: TC ingress AND icmp_rcv both count 5 PTBs.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## Setup

- `tc_ingress_eth0` attached to veth1 ingress in ns1 (TC sched_cls, jited)
- kprobe/icmp_rcv attached globally via probe_attach (id 182, jited)
- No iptables DROP rule active in ns1 (iptables INPUT chain: 0 rules, ACCEPT policy)

### iptables state (clean — no DROP rules)

```
Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
```

---

## Map state BEFORE injection

```
ptb_ingress_total (id 86):  {"key": 0, "value": 0}
icmp_rcv_total    (id 87):  {"key": 0, "value": 0}
```

---

## Injection

```sh
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 \
  --dev veth2 --next-hop-mtu 1400 --count 5
# Sent 5 ICMP PTBs
```

---

## Map state AFTER injection (unsuppressed)

```
ptb_ingress_total (TC ingress, PRE-netfilter):
  {"key": 0, "value": 5}

icmp_rcv_total (POST-netfilter):
  {"key": 0, "value": 5}
```

---

## Result

| Counter | Expected | Actual |
|---------|----------|--------|
| ptb_ingress_total | 5 | **5** ✓ |
| icmp_rcv_total | 5 | **5** ✓ |

Both counters equal 5. This proves:
- The TC ingress hook sees PTBs before netfilter
- When no DROP rule is present, all 5 PTBs pass through netfilter and reach `icmp_rcv`
- TC ingress count == icmp_rcv count → no suppression

---

## What this proves

For the unsuppressed case (no iptables DROP rule):
- TC ingress count (pre-netfilter) = 5 ✓
- icmp_rcv count (post-netfilter) = 5 ✓
- Delta = 0 → PTBs are NOT suppressed

The detection architecture works: the two counters move together when PTBs flow
normally. The suppression signal is the DIFFERENCE between them, proven in Commit 6.

## What remains unproven

Suppression path: ptb_ingress > 0 while icmp_rcv == 0 (Commit 6 runs with
iptables DROP rule for icmptype 3 code 4 active in ns1).
