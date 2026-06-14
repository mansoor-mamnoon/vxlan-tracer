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
