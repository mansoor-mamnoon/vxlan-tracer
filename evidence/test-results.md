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

---

## 2026-06-15 — filtered icmp_rcv counter: ping vs. PTB — Day 5

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, libbpf v1.4.0 built from source
**Command:**
```sh
ip netns exec ns2 ping -c 5 192.168.100.1
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
# /tmp/probe_attach polling loop reading icmp_rcv_total every 2s
```
**Expected:** counter stays 0 across 5 pings, jumps to 5 after 5 injected PTBs, stays at 5
**Actual:**
```
t=2s..t=10s (during pings):    icmp_rcv_total = 0
t=12s (after PTB injection):   icmp_rcv_total = 5
t=14s..t=36s:                  icmp_rcv_total = 5 (stable)
```
**Result:** PASS — kprobe correctly filters to ICMP type=3/code=4, ignoring ping traffic
**Caveat:** Required building libbpf v1.4.0 from source; apt's libbpf0 0.5.0 cannot parse this
kernel's BTF encoding. See evidence/day-05-icmp-rcv-filter.md and day-05-icmp-rcv-verify.md.

---

## 2026-06-15 — Go loader attach: TC ingress/egress + kprobe + map pinning — Day 5

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, Go binary cross-compiled
GOOS=linux GOARCH=arm64 from macOS, invoked via `nsenter --net=/var/run/netns/ns1`
**Command:**
```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs --duration 30s
ip netns exec ns1 tc filter show dev veth1 ingress
ip netns exec ns1 tc filter show dev vxlan0 egress
ls -la /sys/fs/bpf/vxlan-tracer/
```
**Expected:** TC filters attached on both interfaces, all 4 maps pinned, kprobe attached
**Actual:**
```
tc_ingress_eth0 direct-action not_in_hw id 310 jited   (veth1 ingress)
tc_egress_vxlan0 direct-action not_in_hw id 311 jited  (vxlan0 egress)
/sys/fs/bpf/vxlan-tracer/: flow_state, icmp_rcv_total, ptb_ingress_counts, ptb_ingress_total
```
**Result:** PASS — after fixing two bugs (see below), maps pinned/cleaned up correctly,
TC filters and pinned maps survive process exit, exit code 0.
**Caveat:** First two attempts failed: (1) `ip netns exec` unshares the mount namespace and
detaches the bpffs mount, breaking pinning — fixed by using `nsenter --net=...` instead;
(2) program names in the loader didn't match the compiled object's ELF program names — fixed.
See evidence/day-05-go-loader.md for full detail; failures documented, not hidden.

---

## 2026-06-15 — unsuppressed/suppressed PTB tests via Go CLI verdict — Day 5

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, Go binary only (no bpftool, no shell diagnosis script)
**Command:**
```sh
# Run A: no iptables rule
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 --overlay vxlan0 --underlay veth1 \
  --pin-dir /sys/fs/bpf/vxlan-tracer --bpf-dir /tmp/bpfobjs --duration 20s &
ip netns exec ns2 python3 spikes/inject_ptb.py --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5

# Run B: iptables DROP rule for icmp type 3 code 4 installed first
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 ... --duration 20s &
ip netns exec ns2 python3 spikes/inject_ptb.py ... --count 5
```
**Expected:** Run A prints verdict PTB_DELIVERED (5/5); Run B prints verdict PTB_SUPPRESSED (5/0)
**Actual:**
```
Run A: verdict: PTB_DELIVERED
       5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv...
Run B: verdict: PTB_SUPPRESSED
       5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv...
       (iptables packet counter independently confirmed 5 pkts/280 bytes matched the DROP rule)
```
**Result:** PASS — both branches of the Day 5 success condition proven through the actual Go
CLI binary: attach, observe, read pinned maps, diagnose, print verdict, detach.
**Caveat:** Suppression mechanism tested was iptables DROP only; other mechanisms (nftables,
conntrack, security modules) not tested. See evidence/day-05-unsuppressed-go.md and
evidence/day-05-suppressed-go.md.

---

## 2026-06-14/16 — ip_do_fragment kprobe attach via Go loader — Day 6 commit 3

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, Go binary cross-compiled macOS→linux/arm64
**Command:**
```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs --duration 10s
ls /sys/fs/bpf/vxlan-tracer/
```
**Expected:** Binary outputs "kprobe/ip_do_fragment" in attach line; `frag_events_total` present in bpffs
**Actual:**
```
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobes (TC filters remain attached; maps remain pinned)
/sys/fs/bpf/vxlan-tracer/: flow_state  frag_events_total  icmp_rcv_total  ptb_ingress_counts  ptb_ingress_total
```
**Result:** PASS — cilium/ebpf link.Kprobe("ip_do_fragment", prog) succeeds on this kernel
**Caveat:** See evidence/day-06-loader-frag-attach.md.

---

## 2026-06-14/16 — small traffic: frag_events_total = 0 — Day 6 commit 5

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
# vxlan-tracer running in background with --duration 30s
ip netns exec ns1 ping -c 5 -s 40 10.244.0.2
```
**Expected:** frag_events_total stays at 0 for small pings (outer IP ~118B << 1400B underlay MTU)
**Actual:**
```
verdict: VXLAN_MTU_MISCONFIGURATION
(frag_events_total = 0; fall-through to static MTU check)
```
Exit code 0.
**Result:** PASS — ip_do_fragment counter stays at 0 for traffic that fits within underlay MTU
**Caveat:** frag_events_total value not directly printed in human-readable output; inferred from
verdict fall-through. Confirmed directly in JSON output (commit 9): `"frag_events_total":0`.
See evidence/day-06-frag-small.md.

---

## 2026-06-14/16 — large traffic: VXLAN_FRAGMENTATION_OBSERVED confirmed — Day 6 commit 8

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs --duration 30s &
ip netns exec ns1 ping -c 3 -s 1360 10.244.0.2
```
**Expected:** frag_events_total = 6 (3 pings × 2 directions); verdict VXLAN_FRAGMENTATION_OBSERVED
**Actual:**
```
verdict: VXLAN_FRAGMENTATION_OBSERVED
6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached. The kernel
fragmented at least one outgoing IP packet. In the stale-MTU VXLAN scenario this indicates
that outer VXLAN packets exceed the underlay MTU (1400) and are being fragmented rather than
dropped. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab
fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.
```
Exit code 0.
**Result:** PASS — primary Day 6 success condition met
**Caveat:** In-lab fragments reassemble (0% loss for large pings). The blackhole condition
(cloud fabric dropping fragmented UDP) is not reproduced but also not claimed.
CO-RE sk_buff.len relocation resolved correctly from /sys/kernel/btf/vmlinux.
Both ip_do_fragment kprobe attach (commit 3) and CO-RE skb->len read (commit 7)
proven in this test by the binary loading without error.

---

## 2026-06-14/16 — JSON output mode: fragmentation case — Day 6 commit 9

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:**
```sh
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs --duration 20s --json &
# Wait 3s, then:
ip netns exec ns1 ping -c 3 -s 1360 10.244.0.2
```
**Expected:** Single JSON line on stdout with verdict=VXLAN_FRAGMENTATION_OBSERVED, frag_events_total=6, recommended_overlay_mtu=1350
**Actual:**
```json
{"verdict":"VXLAN_FRAGMENTATION_OBSERVED","message":"6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached. The kernel fragmented at least one outgoing IP packet. In the stale-MTU VXLAN scenario this indicates that outer VXLAN packets exceed the underlay MTU (1400) and are being fragmented rather than dropped. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.","overlay":"vxlan0","underlay":"veth1","overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":0,"icmp_rcv_total":0,"frag_events_total":6,"max_outer_ip_len":1438}
```
Exit code 0.
**Result:** PASS
**Caveat:** None.

---

## 2026-06-14/16 — JSON output mode: PTB suppressed case — Day 6 commit 9

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64 (separate container from fragmentation test)
**Command:**
```sh
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP
nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64 \
  --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer \
  --bpf-dir /tmp/bpfobjs --duration 20s --json &
# Wait 3s, then:
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 --next-hop-mtu 1400 --count 5
```
**Expected:** JSON with verdict=PTB_SUPPRESSED, ptb_ingress_total=5, icmp_rcv_total=0
**Actual:**
```json
{"verdict":"PTB_SUPPRESSED","message":"5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.","overlay":"vxlan0","underlay":"veth1","overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":5,"icmp_rcv_total":0,"frag_events_total":0,"max_outer_ip_len":0}
```
Exit code 0.
**Result:** PASS — JSON mode works for the PTB suppression path; regression confirmed
**Caveat:** Separate container required to avoid "TC filter file exists" error from prior run.

---

## 2026-06-16 — Day 7: automated scenario runner (all 4 verdicts)

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, --privileged
**Command:** `BINARY=/tmp/vxlan-tracer-linux-arm64-d7 BPF_DIR=/tmp/bpfobjs DURATION=15s bash scripts/run-scenarios.sh`
**Expected:** 4 scenarios pass with expected verdicts; all exit codes 0
**Actual:**
```
Results: 4 passed, 0 failed
run-scenarios exit: 0
```

Scenario results:
- healthy_small → VXLAN_MTU_MISCONFIGURATION: PASS (max_outer_ip_len=118, no active fault)
- fragmentation → VXLAN_FRAGMENTATION_OBSERVED: PASS (frag_events_total=6, max_outer_ip_len=1438)
- ptb_delivered → PTB_DELIVERED: PASS (ptb_ingress_total=5, icmp_rcv_total=5)
- ptb_suppressed → PTB_SUPPRESSED: PASS (ptb_ingress_total=5, icmp_rcv_total=0)

Each scenario ran idempotent cleanup before setup. No "file exists" errors. No stale counters.
**Result:** PASS (4/4)
**Caveat:** aarch64 kernel only; fragmentation result corroborated (two-signal) because fresh cleanup
resets route MTU cache via namespace recreation.

---

## 2026-06-17 — Day 8: 5-scenario run including second-run idempotency

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, --privileged
**Command:** `BINARY=/tmp/vxlan-tracer-linux-arm64-d8 BPF_DIR=/tmp/bpfobjs DURATION=15s bash scripts/run-scenarios.sh`
**Expected:** 5 scenarios pass; fragmentation second-run reports global_corroborated after route cache flush
**Actual:**
```
Results: 5 passed, 0 failed
```

Scenario results:
- healthy_small → VXLAN_MTU_MISCONFIGURATION: PASS
- fragmentation → VXLAN_FRAGMENTATION_OBSERVED: PASS (fragmentation_scope=global_corroborated, max_outer_ip_len=1438)
- ptb_delivered → PTB_DELIVERED: PASS
- ptb_suppressed → PTB_SUPPRESSED: PASS
- fragmentation (second run, route cache flushed) → VXLAN_FRAGMENTATION_OBSERVED: PASS (fragmentation_scope=global_corroborated, max_outer_ip_len=1438)

**Result:** PASS (5/5)
**Caveat:** aarch64 / 6.10.14-linuxkit only. `ip route flush cache` used for second run to clear PMTU cache.
See evidence/day-08-scenario-rerun.md and evidence/day-08-route-cache.md.

---

## 2026-06-17 — Day 8: bpf_get_netns_cookie availability probe

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, Go cilium/ebpf loader
**Command:** `go run spikes/probe_helper/main.go` (after compiling both probe BPF objects)
**Expected:** Determine whether bpf_get_netns_cookie is available for kprobe or sched_cls program types
**Actual:**
```
kprobe: UNSUPPORTED — program of this type cannot use helper bpf_get_netns_cookie#122
sched_cls: UNSUPPORTED — program of this type cannot use helper bpf_get_netns_cookie#122
```
**Result:** CONFIRMED UNAVAILABLE — netns cookie scoping of ip_do_fragment is not feasible
**Caveat:** Restriction is in the kernel's allowed_prog_types for the helper. Not a 6.10.14 regression;
this design decision also applies to 5.15.x (verified via kernel source review).
See evidence/day-08-helper-availability.md.

---

## 2026-06-17 — Day 8: ip_do_fragment header parsing spike

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Command:** `spikes/probe_frag_scope/main.go` with `spikes/probe_frag_scope.bpf.c` loaded
**Expected:** Determine whether skb->network_header reliably points to outer IP header at ip_do_fragment
**Actual (with route MTU cache active):**
```
skb_len=1388, ip_proto=1 (ICMP), is_vxlan=0
frag_vxlan_count=2, frag_total=6
```
skb_len=1388 is the inner packet length (outer=1438). ip_proto=1 is the inner IP proto (ICMP ping).
network_header pointed to inner IP header, not outer.
**Result:** CONFIRMED UNRELIABLE — header parsing deferred; two-signal corroboration chosen
**Caveat:** First-run events (before route cache) correctly showed ip_proto=17, dport=4789.
Inconsistency is cache-state-dependent. Not usable as reliable VXLAN filter.
See evidence/day-08-frag-scope-spike.md.

---

## 2026-06-17 — Day 9: preflight check on Lima VM (5.15.0-181-generic)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64, root
**Command:** `sudo bash scripts/preflight.sh`
**Expected:** All checks pass
**Actual:**
```
PASS: 20  WARN: 0  FAIL: 0
RESULT: PASS — all checks passed.
```
Notable: ip_do_fragment and icmp_rcv confirmed T symbols. bpftool kernel-matched (v5.15.199).
**Result:** PASS (20/20)
**Caveat:** aarch64 only. x86_64 not tested.

---

## 2026-06-17 — Day 9: BPF compile on Lima VM (5.15.0-181-generic)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64, clang 14
**Command:** `make bpf`
**Expected:** All four BPF objects compile; 0 warnings
**Actual:**
```
prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=aarch64
CC  bpf/tc_ingress_eth0.bpf.o   (18K)
CC  bpf/tc_egress_vxlan0.bpf.o  (17K)
CC  bpf/kprobes.bpf.o            (7.6K)
CC  bpf/frag_kprobes.bpf.o       (7.5K)
BPF build complete.
```
Bug fixed in this run: frag_kprobes.bpf.o was previously missing from make bpf target.
**Result:** PASS (0 warnings, all 4 objects)
**Caveat:** aarch64 only. x86_64 BPF compile (CFLAGS_BPF with __TARGET_ARCH_x86) not tested.

---

## 2026-06-17 — Day 9: scenario suite on Lima VM (5.15.0-181-generic) — 5/5 PASS

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64, root
**Command:** `BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`
**Expected:** 5/5 pass with same verdicts as linuxkit
**Actual:**
```
Results: 5 passed, 0 failed
```
Per-scenario:
- healthy_small     → VXLAN_MTU_MISCONFIGURATION   PASS  (max_outer_ip_len=118)
- fragmentation     → VXLAN_FRAGMENTATION_OBSERVED  PASS  (frag_events_total=6, scope=global_corroborated)
- ptb_delivered     → PTB_DELIVERED                 PASS  (ptb_ingress_total=5, icmp_rcv_total=5)
- ptb_suppressed    → PTB_SUPPRESSED                PASS  (ptb_ingress_total=5, icmp_rcv_total=0)
- fragmentation x2  → VXLAN_FRAGMENTATION_OBSERVED  PASS  (scope=global_corroborated, max_outer_ip_len=1438)

**Result:** PASS (5/5) — first non-linuxkit kernel validation
**Caveat:** aarch64 only. All JSON field values identical to 6.10.14-linuxkit. See evidence/day-09-vm-scenarios.md.

---

## 2026-06-17 — Day 9: bpf_get_netns_cookie probe on Lima VM (5.15.0-181-generic)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64
**Command:** `probe_helper --kprobe probe_netns_cookie_kprobe.bpf.o --cls probe_netns_cookie_cls.bpf.o`
**Expected:** UNSUPPORTED (same as linuxkit, different error message)
**Actual:**
```
[kprobe] FAILED: unknown func bpf_get_netns_cookie#122
[sched_cls] FAILED: unknown func bpf_get_netns_cookie#122
kprobe bpf_get_netns_cookie: UNSUPPORTED
sched_cls bpf_get_netns_cookie: UNSUPPORTED
```
Error message differs from linuxkit ("program of this type cannot use helper" vs "unknown func").
**Result:** CONFIRMED UNSUPPORTED on 5.15.0-181-generic
**Caveat:** Different error wording between kernel versions; same practical conclusion.

---

## 2026-06-17 — Day 9: header parsing spike on Lima VM (5.15.0-181-generic)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64
**Command:** `probe_frag_scope --obj probe_frag_scope.bpf.o --duration 12s` + 3 large pings
**Expected:** network_header inconsistency (as on linuxkit); inner IP may be visible
**Actual:**
```
skb_len: 1388, ip_proto: 1 (ICMP), udp_dport: 0, is_vxlan: 0
frag_vxlan_count: 2
```
Even on first run (no prior route cache), inner IP seen. On linuxkit, first run sometimes showed outer IP.
**Result:** CONFIRMED MORE SEVERE — header parsing never sees outer IP on 5.15.0-181-generic
**Caveat:** Two-signal corroboration strategy is the correct approach and is confirmed here.

---

## 2026-06-18 — Day 10: full scenario suite on x86_64 6.8.0-1052-azure (GitHub Actions)

**Environment:** GitHub Actions ubuntu-22.04 runner, Azure westus, kernel 6.8.0-1052-azure, x86_64, root (sudo)
**Command:** `sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`
**Run:** GitHub Actions run 27743797987 (commit b66a4c4)
**Expected:** 5/5 pass — first x86_64 run
**Actual:**
```
Results: 5 passed, 0 failed
```
Per-scenario:
- healthy_small     → VXLAN_MTU_MISCONFIGURATION   PASS  (max_outer_ip_len=118)
- fragmentation     → VXLAN_FRAGMENTATION_OBSERVED  PASS  (frag_events_total=6, frag_max_skb_len=1438, scope=global_corroborated)
- ptb_delivered     → PTB_DELIVERED                 PASS  (ptb_ingress_total=5, icmp_rcv_total=5)
- ptb_suppressed    → PTB_SUPPRESSED                PASS  (ptb_ingress_total=5, icmp_rcv_total=0)
- fragmentation x2  → VXLAN_FRAGMENTATION_OBSERVED  PASS  (scope=global_corroborated, frag_max_skb_len=1438)

**Result:** PASS (5/5) — first confirmed x86_64 run; PT_REGS_PARM1 x86 convention works
**Caveat:** Runner uses Azure kernel (6.8.0-1052-azure), not canonical Ubuntu 5.15.x. clsact qdisc probe in preflight fails at global netns level (runner restriction), but TC ops inside netns succeed. See evidence/day-10-x86-vm-scenarios.md.

---

## 2026-06-18 — Day 12: 6/6 scenario suite on Lima VM (5.15.0-181-generic) including port 8472

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64, root
**Command:** `sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`
**Expected:** 6/6 pass — scenarios 1–5 unaffected by vxlan_config map addition; scenario 6 PTB_DELIVERED with vxlan_port=8472
**Actual:**
```
Results: 6 passed, 0 failed
```

Per-scenario:
- healthy_small          → VXLAN_MTU_MISCONFIGURATION   PASS  (vxlan_port=4789, vxlan_vni=42)
- fragmentation          → VXLAN_FRAGMENTATION_OBSERVED  PASS  (frag_events_total=6, scope=global_corroborated)
- ptb_delivered          → PTB_DELIVERED                 PASS  (ptb_ingress_total=5, icmp_rcv_total=5, vxlan_port=4789)
- ptb_suppressed         → PTB_SUPPRESSED                PASS  (ptb_ingress_total=5, icmp_rcv_total=0, vxlan_port=4789)
- fragmentation (2nd run)→ VXLAN_FRAGMENTATION_OBSERVED  PASS  (scope=global_corroborated)
- ptb_delivered port=8472→ PTB_DELIVERED                 PASS  (ptb_ingress_total=5, icmp_rcv_total=5, vxlan_port=8472)

Scenario 6 JSON: `"verdict":"PTB_DELIVERED","vxlan_port":8472,"vxlan_vni":42,"ptb_ingress_total":5,"icmp_rcv_total":5`

**Result:** PASS (6/6)
**Caveat:** 5.15.0-181-generic aarch64 only for scenario 6. Non-4789 scenario not run on x86_64 or 6.10.14-linuxkit. Netns lab only — not a real CNI node. See evidence/day-12-scenarios-8472.md.

---

## 2026-06-19 — Day 13: loader unit tests (fail-closed vxlan_config guard)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64 (local); also confirmed on x86_64 6.8.0-1059-azure (CI)
**Command:** `go test ./internal/loader/ -v`
**Expected:** TestWriteVXLANPortToMapsMissing and TestWriteVXLANPortToMapsMissingPort0 both PASS
**Actual:**
```
=== RUN   TestWriteVXLANPortToMapsMissing
--- PASS: TestWriteVXLANPortToMapsMissing (0.00s)
=== RUN   TestWriteVXLANPortToMapsMissingPort0
--- PASS: TestWriteVXLANPortToMapsMissingPort0 (0.00s)
PASS  ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.002s  (local)
PASS  ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.003s  (CI x86_64)
```
**Result:** PASS (both tests on both architectures)
**Caveat:** Tests verify error path using an empty `map[string]*ebpf.Map{}`. They do not load
a real BPF object — they only confirm that the loader returns a non-nil error with the expected
message when the map is absent. See evidence/day-13-stale-bpf-guard.md.

---

## 2026-06-19 — Day 13: make bpf-verify on fresh 19K object

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64
**Command:** `make bpf-verify`
**Expected:** PASS — vxlan_config symbol found in ELF symbol table
**Actual:**
```
  PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section
```
**Result:** PASS
**Caveat:** Initial implementation used `readelf -S` (section headers) — wrong; vxlan_config is a
symbol within the .maps section, not a section header entry. Fixed to `readelf -s` (symbol table).

---

## 2026-06-19 — Day 13: 6/6 scenario suite after fail-closed loader (Lima VM)

**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64, root
**Command:** `sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`
**Expected:** 6/6 pass with fail-closed loader in place (fresh 19K object)
**Actual:**
```
Results: 6 passed, 0 failed
```
- healthy_small          → VXLAN_MTU_MISCONFIGURATION   PASS
- fragmentation          → VXLAN_FRAGMENTATION_OBSERVED  PASS (scope=global_corroborated)
- ptb_delivered          → PTB_DELIVERED                 PASS (vxlan_port=4789)
- ptb_suppressed         → PTB_SUPPRESSED                PASS (vxlan_port=4789)
- fragmentation (2nd)    → VXLAN_FRAGMENTATION_OBSERVED  PASS (scope=global_corroborated)
- ptb_delivered port=8472→ PTB_DELIVERED                 PASS (vxlan_port=8472, vxlan_vni=42)

**Result:** PASS (6/6)
**Caveat:** See evidence/day-13-local-6-scenarios.md.

---

## 2026-06-19 — Day 13: 6/6 scenario suite on x86_64 6.8.0-1059-azure (GitHub Actions run 27851298262)

**Environment:** GitHub Actions ubuntu-22.04, kernel 6.8.0-1059-azure x86_64, root
**Command:** `sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh`
**Run:** 27851298262, job conclusion: PASS
**Expected:** 6/6 pass on x86_64 including port 8472
**Actual:**
```
Results: 6 passed, 0 failed
All 6 binary exits: 0
```
- Scenarios 1–5: identical to prior x86_64 5/5 result (6.8.0-1052-azure)
- Scenario 6: `{"verdict":"PTB_DELIVERED","vxlan_port":8472,"ptb_ingress_total":5,"icmp_rcv_total":5}`

bpf-verify: `PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section`
Loader unit tests: `ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.003s`

**Result:** PASS (6/6) — first x86_64 run including port 8472
**Caveat:** Preflight ENVIRONMENT failure (ip link add dummy blocked); step has `continue-on-error: true`;
job conclusion was PASS. Netns lab only. See evidence/day-13-x86-8472-result.md.
