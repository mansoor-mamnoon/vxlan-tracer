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

## 2026-06-14 — Go unit tests (macOS)

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

## PENDING — netns lab setup (requires Linux)

**Environment:** Linux 5.15+ host (not yet available)
**Command:** `sudo bash scripts/setup-netns.sh`
**Expected:** ns1, ns2 created; vxlan0 at 10.244.0.1 and 10.244.0.2; MTU 1500 (wrong)
**Actual:** COULD NOT RUN — macOS development environment
**Result:** SKIP
**Caveat:** Must run on Linux with root and iproute2 installed.

---

## PENDING — ip_do_fragment symbol check (requires Linux)

**Environment:** Linux 5.15+ host (not yet available)
**Command:** `grep ip_do_fragment /proc/kallsyms`
**Expected:** One line showing `ip_do_fragment` as `T` (text/exported function)
**Actual:** COULD NOT RUN — macOS development environment
**Result:** SKIP
**Caveat:** If symbol absent (inlined), must fall back to `__ip_finish_output` kprobe.

---

## PENDING — bpftrace ip_do_fragment probe (requires Linux)

**Environment:** Linux 5.15+ host, bpftrace 0.16+, root
**Command:**
```sh
# Terminal 1:
sudo bpftrace spikes/bpftrace/ip_do_fragment.bt
# Terminal 2 (after lab-up):
ip netns exec ns1 curl --max-time 30 http://10.244.0.2/large.bin -o /dev/null
```
**Expected:** Lines showing `[ip_do_fragment] outer_len=1564 dev=veth1 dev_mtu=1500 excess=64`
**Actual:** COULD NOT RUN
**Result:** SKIP
**Caveat:** See docs/lab-topology.md for note on local netns fragmentation reassembly.

---

## PENDING — smoke-small-traffic (requires Linux)

**Environment:** Linux 5.15+ host, root, lab up
**Command:** `sudo bash scripts/smoke-small-traffic.sh`
**Expected:** 4/4 PASS
**Actual:** COULD NOT RUN
**Result:** SKIP

---

## PENDING — smoke-large-traffic (requires Linux)

**Environment:** Linux 5.15+ host, root, lab up
**Command:** `sudo bash scripts/smoke-large-traffic.sh`
**Expected:** Records actual behavior; may show fragmentation or stall
**Actual:** COULD NOT RUN
**Result:** SKIP
**Caveat:** In local netns+veth with DF=0, large traffic may succeed despite
fragmentation (no middlebox to drop fragments). This is documented.
