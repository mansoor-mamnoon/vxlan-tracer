# evidence/test-results.md

Records of actual test runs. Not fabricated.
Each entry includes: date, environment, command, actual output, pass/fail.

## Format

```
### YYYY-MM-DD — <test name>
Environment: <OS, kernel, tool versions>
Command: <exact command>
Expected: <what was expected>
Actual: <actual output or COULD NOT RUN>
Result: PASS / FAIL / SKIP (with reason)
Caveat: <any known caveat>
```

---

## 2026-06-14 — Go unit tests (macOS) — Day 1

**Environment:** macOS 25.0.0 arm64, go1.26.3
**Command:** `go test ./internal/diag/ -v`
**Expected:** MTU arithmetic tests pass
**Actual:**
```
=== RUN   TestCheckMTU
=== RUN   TestCheckMTU/correct:_overlay_1450,_underlay_1500
=== RUN   TestCheckMTU/wrong:_overlay_1500_(default),_underlay_1500
=== RUN   TestCheckMTU/cloud_MTU_9000:_overlay_8950,_underlay_9000
=== RUN   TestCheckMTU/cloud_MTU_9000,_overlay_still_1500
--- PASS: TestCheckMTU (0.00s)
=== RUN   TestProjectedOuterFrame
--- PASS: TestProjectedOuterFrame (0.00s)
=== RUN   TestMaxSafeInnerIPLen
--- PASS: TestMaxSafeInnerIPLen (0.00s)
PASS
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag 0.317s
```
**Result:** PASS (6 subtests)
**Caveat:** None. Pure Go, no kernel dependency.

---

## 2026-06-14 — go vet (macOS)

**Environment:** macOS 25.0.0 arm64, go1.26.3
**Command:** `go vet ./...`
**Expected:** No errors
**Actual:** (no output)
**Result:** PASS
**Caveat:** None.

---

## 2026-06-14 — shell script syntax checks (macOS)

**Environment:** macOS 25.0.0, bash 3.2.57
**Commands:**
```sh
bash -n scripts/setup-netns.sh
bash -n scripts/teardown-netns.sh
bash -n scripts/smoke-small-traffic.sh
bash -n scripts/smoke-large-traffic.sh
```
**Expected:** No syntax errors
**Actual:** All returned exit code 0, no output
**Result:** PASS
**Caveat:** Syntax only. Execution requires Linux with root.

---

## 2026-06-14 — netns lab setup (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, --privileged
**Command:** setup via Docker run --privileged; see evidence/day-02-lab-setup.md
**Expected:** ns1, ns2 created; vxlan0 at 10.244.0.1 and 10.244.0.2; underlay stale MTU scenario
**Actual:**
```
vxlan0 MTU after creation: 1450 (kernel auto-set; cannot set to 1500 on 6.10.14)
veth1 MTU after reduction: 1400
vxlan0 MTU (stale): 1450 (not reduced when underlay changed)
underlay ping (ns1→ns2): OK
overlay small ping (10.244.0.1→10.244.0.2): OK
```
**Result:** PASS (with alternative topology; see evidence/day-02-lab-setup.md)
**Caveat:** Kernel 6.10.14 enforces max vxlan0 MTU = underlay - 50; cannot set to 1500.
Alternative: reduce underlay MTU after vxlan0 creation to create stale-MTU scenario.

---

## 2026-06-14 — ip_do_fragment symbol check (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:** `grep -E '^[0-9a-f]+ T ip_do_fragment$' /proc/kallsyms`
**Expected:** One line showing `ip_do_fragment` as T symbol
**Actual:**
```
ffff800080ff71d8 T ip_do_fragment
```
**Result:** PASS — ip_do_fragment is a kprobeable T symbol on kernel 6.10.14
**Caveat:** None. Confirmed in /proc/kallsyms inside privileged container.

---

## 2026-06-14 — icmp_send symbol check (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:** `grep -E '^[0-9a-f]+ T icmp_send$' /proc/kallsyms`
**Expected:** T symbol for kprobe attachment
**Actual:** (no output — icmp_send is NOT a T symbol)
**Result:** FINDING — icmp_send not directly kprobeable; use tracepoint:net:icmp_send
**Caveat:** `__traceiter_icmp_send` IS a T symbol (tracepoint iterator). icmp_send.bt updated.

---

## 2026-06-14 — ip_do_fragment ftrace kprobe: small traffic (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
echo 'p:ip_do_frag ip_do_fragment' > /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/ip_do_frag/enable
echo 1 > /sys/kernel/tracing/tracing_on
ip netns exec ns1 ping -c 5 -s 40 -q 10.244.0.2
grep ip_do_frag /sys/kernel/tracing/trace | wc -l
```
**Expected:** 0 ip_do_fragment events (outer IP 118B < underlay 1400)
**Actual:** 0
**Result:** PASS — small traffic does not trigger ip_do_fragment

---

## 2026-06-14 — ip_do_fragment ftrace kprobe: large traffic (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
ip netns exec ns1 ping -c 10 -s 1360 -q 10.244.0.2
grep ip_do_frag /sys/kernel/tracing/trace | wc -l
```
**Expected:** >0 events (outer IP 1438B > underlay 1400)
**Actual:**
```
20    # 2 events per ping × 10 pings = 20
```
First event: `ping-54795 [009] D.... 166350.859507: ip_do_frag: (ip_do_fragment+0x0/0x508)`
**Result:** PASS — ip_do_fragment fires for every oversized outer VXLAN packet
**Caveat:** Field values (outer_ip_len, dev_mtu) not captured; ftrace gives entry point only.
Full bpftrace execution requires bpftrace 0.16+ on a VM with matching kernel headers.

---

## 2026-06-14 — bpftrace ip_do_fragment probe (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, bpftrace 0.14.0, kernel 6.10.14-linuxkit
**Command:** `bpftrace -e 'kprobe:ip_do_fragment { printf("hit\n"); exit(); }'`
**Expected:** Probe attaches and fires
**Actual:**
```
/bpftrace/include/clang_workarounds.h:14:10: fatal error: 'linux/types.h' file not found
```
**Result:** FAIL — bpftrace 0.14.0 packaging broken on linuxkit
**Caveat:** Raw ftrace confirmed the hook fires. bpftrace 0.16+ on Lima VM needed for field access.

---

## 2026-06-14 — DF=1 blackhole confirmation (Docker linuxkit)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit; vxlan0 df=set
**Command:** `ip netns exec ns1 ping -c 3 -s 1360 -M do -q 10.244.0.2`
**Expected:** 100% packet loss (outer IP DF=1, 1438B > 1400B underlay)
**Actual:**
```
3 packets transmitted, 0 received, 100% packet loss, time 2041ms
```
**Result:** PASS — DF=1 blackhole confirmed
**Caveat:** None. Small pings unaffected (3/3 received).

---

## 2026-06-14 — tc_ingress_eth0.bpf.c compile + BPF verifier — Day 3

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, clang 14
**Command:**
```sh
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o /tmp/tc_ingress_eth0.bpf.o
tc filter add dev veth1 ingress bpf da obj /tmp/tc_ingress_eth0.bpf.o sec tc
tc filter show dev veth1 ingress
```
**Expected:** Compile 0 warnings; tc filter shows `jited`
**Actual:**
```
(compile) Exit: 0, 0 warnings, 18K ELF object
(tc filter) direct-action not_in_hw id 157 tag 20bd2d524d2b4592 jited
```
**Result:** PASS — BPF verifier accepted; JIT compiled
**Caveat:** First compile attempt failed with IPPROTO_ICMP undefined; fixed by adding `#include <linux/in.h>`

---

## 2026-06-14 — synthetic PTB injection (5 PTBs) — Day 3

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
bpftool map dump id <ptb_ingress_counts>
bpftool map dump id <ptb_ingress_total>
```
**Expected:** ptb_count=5, ptb_ingress_total=5, next_hop_mtu=1400
**Actual:**
```
ptb_count: 5 ✓
ptb_ingress_total: 5 ✓
next_hop_mtu: 0 ✗ (bug in inject_ptb.py: used unused= instead of nexthopmtu=)
```
**Result:** PARTIAL — count correct; MTU field 0 due to test script bug (fixed in same commit)
**Caveat:** inject_ptb.py fixed to use `nexthopmtu=` field; re-test scheduled for Day 4.

---

## 2026-06-14 — tc_egress_vxlan0 attach and flow map — Day 3

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
tc filter add dev vxlan0 egress bpf da obj /tmp/tc_egress_vxlan0.bpf.o sec tc
ping -c 3 -s 56 10.0.0.2   # small traffic
ping -c 3 -s 1400 10.0.0.2  # large traffic
bpftool map dump id <flow_state>
```
**Expected:** jited attachment; flow_state has 1 entry; max_inner_ip_len matches large ping
**Actual:**
```
tc filter: direct-action not_in_hw id 161 tag 8d5c7a9a173ff918 jited ✓
small ping 3/3 received ✓
large ping 3/3 received ✓
flow_state: src=10.0.0.1 dst=10.0.0.2 proto=ICMP pkt_count=6
  max_inner_ip_len=1428  max_outer_ip_len=1478 (= 1428+50) ✓
ptb_ingress_counts: [] (empty — correct, outer IP 1478 < underlay MTU 1500) ✓
```
**Result:** PASS
**Caveat:** Blackhole scenario (outer IP > underlay MTU) not yet tested here;
requires alternative topology (underlay MTU=1400, scheduled for Day 4).

---

## 2026-06-14 — internal/bpfmap Go unit tests — Day 3

**Environment:** macOS 25.0.0 arm64, go1.26.3
**Command:** `go test ./internal/bpfmap/ -v`
**Expected:** All 6 tests pass; IP conversion correct for VTEP addresses
**Actual:**
```
--- PASS: TestParsePTBCounts (0.00s)
--- PASS: TestParsePTBCountsEmpty (0.00s)
--- PASS: TestParsePTBCountsBadJSON (0.00s)
--- PASS: TestParsePTBTotal (0.00s)
--- PASS: TestParsePTBTotalZero (0.00s)
--- PASS: TestLeU32ToIP (0.00s)
PASS
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap  0.447s
```
**Result:** PASS (6 tests)
**Caveat:** Pure Go, no BPF or kernel dependency. Tests parse fixture from day-03 PTB injection.

---

## 2026-06-14 — inject_ptb.py retest after nexthopmtu= fix — Day 4

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
bpftool map dump id <ptb_ingress_counts>
```
**Expected:** ptb_count=5, next_hop_mtu=1400 (not 0 as in Day 3)
**Actual:**
```json
[{"key": {"ptb_src_ip": 40151232, "ptb_dst_ip": 23374016},
  "value": {"ptb_count": 5, "next_hop_mtu": 1400}}]
```
**Result:** PASS — next_hop_mtu=1400 confirmed after switching inject_ptb.py to `nexthopmtu=` field
**Caveat:** None. Fix confirmed working. See evidence/day-04-ptb-ingress-retest.md.

---

## 2026-06-14 — kprobe/icmp_rcv attach via probe_attach — Day 4

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, libbpf
**Command:**
```sh
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -c bpf/kprobes.bpf.c -o /tmp/kprobes.bpf.o
gcc -O2 -o /tmp/probe_attach spikes/probe_attach.c -lbpf
/tmp/probe_attach /tmp/kprobes.bpf.o 5
bpftool prog list | grep kprobe_icmp_rcv
```
**Expected:** kprobe attaches; bpftool shows jited program with icmp_rcv_total map
**Actual:**
```
(compile) 0 warnings, 96B bytecode, 5.5K ELF, section kprobe/icmp_rcv
182: kprobe  name kprobe_icmp_rcv  tag ...  jited 192B  map_ids 87
```
**Result:** PASS — kprobe attaches via libbpf on kernel 6.10.14
**Caveat:** bpftool v5.15.199 (not matching running kernel 6.10.14); JIT confirms acceptance.

---

## 2026-06-14 — unsuppressed PTB path: TC ingress + icmp_rcv both count — Day 4

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
# No iptables DROP rule
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
bpftool map dump id <ptb_ingress_total>
bpftool map dump id <icmp_rcv_total>
```
**Expected:** Both counters = 5 (PTBs arrive and reach icmp_rcv)
**Actual:**
```
ptb_ingress_total: [{"key": 0, "value": 5}]
icmp_rcv_total:    [{"key": 0, "value": 5}]
```
**Result:** PASS — both counters match; PTBs traversed netfilter INPUT and reached icmp_rcv
**Caveat:** See evidence/day-04-unsuppressed.md. icmp_rcv counts ALL ICMP; isolated by lab.

---

## 2026-06-14 — PTB suppression detection proof — Day 4

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j DROP
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
bpftool map dump id <ptb_ingress_total>
bpftool map dump id <icmp_rcv_total>
ip netns exec ns1 iptables -L INPUT -v -n
```
**Expected:** ptb_ingress_total=5, icmp_rcv_total=0, iptables=5 drops
**Actual:**
```
ptb_ingress_total: [{"key": 0, "value": 5}]
icmp_rcv_total:    [{"key": 0, "value": 0}]
iptables: 5 pkts/280 bytes matched DROP rule (icmptype 3 code 4)
```
**Result:** PASS — PTB suppression detected: TC ingress > 0, icmp_rcv == 0
**Caveat:** Lab uses synthetic PTBs. In production, PTBs arrive from cloud fabric. Mechanism
is identical. See evidence/day-04-ptb-suppression.md for kernel path diagram.
