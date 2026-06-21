#!/usr/bin/env bash
# scripts/test-tc-coexistence.sh
#
# TC coexistence integration tests for vxlan-tracer.
#
# REQUIREMENTS:
#   - Linux, kernel >= 5.15
#   - Root (CAP_NET_ADMIN for netlink TC operations)
#   - iproute2 (ip, tc)
#   - vxlan-tracer binary compiled and available (set VT_BIN or pass --bin)
#   - BPF objects compiled (set BPF_DIR or pass --bpf-dir)
#   - bpffs mounted at /sys/fs/bpf (run scripts/setup-bpf-fs.sh if needed)
#
# CASES:
#   A  Unrelated ingress filter preserved after run
#   B  Unrelated egress filter preserved after run
#   C  Priority collision: vt does not delete non-owned filter
#   D  Partial attach failure: rollback removes only vt resources
#   E  Signal cleanup (SIGINT, SIGTERM): owned resources cleaned
#   F  Repeated runs succeed; no stale filters or maps remain
#
# USAGE:
#   sudo bash scripts/test-tc-coexistence.sh [--bin /path/to/vxlan-tracer] \
#       [--bpf-dir /path/to/bpf] [--pin-dir /sys/fs/bpf/vxlan-tracer-test]
#
# EXIT CODE:
#   0  all cases PASS
#   1  one or more cases FAIL

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

VT_BIN="${VT_BIN:-./vxlan-tracer}"
BPF_DIR="${BPF_DIR:-bpf}"
PIN_DIR="${PIN_DIR:-/sys/fs/bpf/vxlan-tracer-coexist-test}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin)      VT_BIN="$2";    shift 2 ;;
        --bpf-dir)  BPF_DIR="$2";   shift 2 ;;
        --pin-dir)  PIN_DIR="$2";   shift 2 ;;
        *)          echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

_pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
_skip() { echo "  SKIP  $*"; SKIP=$((SKIP+1)); }
_info() { echo "  INFO  $*"; }
_hdr()  { echo; echo "=== Case $* ==="; }

cleanup_veth() {
    ip link del "${UNDERLAY}" 2>/dev/null || true
    ip link del "${OVERLAY}"  2>/dev/null || true
    rm -f /run/vxlan-tracer.lock
    rm -rf "${PIN_DIR}"
}

# Create a minimal two-interface lab (dummy veth pair used as underlay/overlay
# stand-ins; we only need clsact + TC filters, not real VXLAN traffic).
UNDERLAY="vt-ulay-$$"
OVERLAY="vt-olay-$$"

setup_veth() {
    ip link add "${UNDERLAY}" type dummy 2>/dev/null \
        || { echo "ip link add dummy failed — skipping all cases" >&2; exit 2; }
    ip link set "${UNDERLAY}" up
    ip link add "${OVERLAY}" type dummy 2>/dev/null
    ip link set "${OVERLAY}" up
    tc qdisc add dev "${UNDERLAY}" clsact 2>/dev/null || true
    tc qdisc add dev "${OVERLAY}"  clsact 2>/dev/null || true
    mkdir -p "${PIN_DIR}"
}

# Attach a harmless matchall filter at priority $1 handle $2 on interface $3
# direction $4 (ingress|egress). Returns the tc handle string.
add_sentinel_filter() {
    local prio="$1" handle="$2" iface="$3" dir="$4"
    tc filter add dev "${iface}" "${dir}" prio "${prio}" handle "${handle}" \
        protocol all matchall action ok 2>/dev/null \
        || { echo "add_sentinel_filter failed" >&2; return 1; }
}

# Assert a filter at priority $1 handle $2 on interface $3 direction $4 exists.
assert_filter_exists() {
    local prio="$1" handle="$2" iface="$3" dir="$4" label="$5"
    local found
    found=$(tc filter show dev "${iface}" "${dir}" prio "${prio}" 2>/dev/null \
            | grep -c "handle ${handle}" || true)
    if [[ "${found}" -ge 1 ]]; then
        _pass "${label}: sentinel filter still present (prio ${prio} handle ${handle})"
    else
        _fail "${label}: sentinel filter was REMOVED (prio ${prio} handle ${handle} on ${iface} ${dir})"
    fi
}

# Assert no vxlan-tracer filter at prio 50000 on interface $1 direction $2.
assert_no_vt_filter() {
    local iface="$1" dir="$2" label="$3"
    local found
    found=$(tc filter show dev "${iface}" "${dir}" prio 50000 2>/dev/null \
            | grep -c "handle" || true)
    if [[ "${found}" -eq 0 ]]; then
        _pass "${label}: no vxlan-tracer filter remains (prio 50000 on ${iface} ${dir})"
    else
        _fail "${label}: vxlan-tracer filter still present after cleanup"
    fi
}

# Assert the pin dir is gone or empty (no pinned map files).
assert_maps_cleaned() {
    local label="$1"
    local count
    count=$(find "${PIN_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if [[ "${count}" -eq 0 ]]; then
        _pass "${label}: no pinned maps remain under ${PIN_DIR}"
    else
        _fail "${label}: ${count} pinned map file(s) remain under ${PIN_DIR}"
    fi
}

# Run vxlan-tracer for 2 seconds in the background; echo its pid.
run_vt_bg() {
    "${VT_BIN}" \
        --overlay "${OVERLAY}" \
        --underlay "${UNDERLAY}" \
        --bpf-dir "${BPF_DIR}" \
        --pin-dir "${PIN_DIR}" \
        --duration 2s \
        >/dev/null 2>&1 &
    echo $!
}

# ── Pre-flight guards ─────────────────────────────────────────────────────────

echo ""
echo "=== TC coexistence integration test ==="
_info "underlay iface: ${UNDERLAY}"
_info "overlay iface:  ${OVERLAY}"
_info "vxlan-tracer:   ${VT_BIN}"
_info "bpf dir:        ${BPF_DIR}"
_info "pin dir:        ${PIN_DIR}"

if [[ $EUID -ne 0 ]]; then
    echo "FATAL: must run as root" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "FATAL: Linux required" >&2
    exit 2
fi

if [[ ! -x "${VT_BIN}" ]]; then
    echo "FATAL: vxlan-tracer binary not found at ${VT_BIN}" >&2
    echo "  Build: make && cp build/vxlan-tracer-linux-amd64 vxlan-tracer" >&2
    exit 2
fi

if [[ ! -f "${BPF_DIR}/tc_ingress_eth0.bpf.o" ]]; then
    echo "FATAL: BPF objects not found at ${BPF_DIR}" >&2
    echo "  Build: make bpf" >&2
    exit 2
fi

trap 'cleanup_veth' EXIT
setup_veth

# ── Case A: Unrelated ingress filter preserved ────────────────────────────────

_hdr "A — unrelated ingress filter preserved"

# Add a sentinel matchall filter at priority 100 (well away from vt's prio 50000)
# on the underlay ingress. vxlan-tracer must not touch it.
SENTINEL_PRIO=100
SENTINEL_HANDLE="0x1a"
if add_sentinel_filter "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress; then
    _info "sentinel filter added: dev ${UNDERLAY} ingress prio ${SENTINEL_PRIO} handle ${SENTINEL_HANDLE}"

    # Run vxlan-tracer for 2s (attach + diagnostic window + exit + cleanup).
    "${VT_BIN}" \
        --overlay "${OVERLAY}" \
        --underlay "${UNDERLAY}" \
        --bpf-dir "${BPF_DIR}" \
        --pin-dir "${PIN_DIR}" \
        --duration 2s \
        >/dev/null 2>&1
    VT_EXIT=$?

    _info "vxlan-tracer exit code: ${VT_EXIT}"
    assert_filter_exists "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress "A"
    assert_no_vt_filter "${UNDERLAY}" ingress "A"
    assert_maps_cleaned "A"

    # Remove sentinel.
    tc filter del dev "${UNDERLAY}" ingress prio "${SENTINEL_PRIO}" 2>/dev/null || true
else
    _skip "A: could not add sentinel filter (matchall not available in this kernel?)"
fi

# ── Case B: Unrelated egress filter preserved ─────────────────────────────────

_hdr "B — unrelated egress filter preserved"

if add_sentinel_filter "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${OVERLAY}" egress; then
    _info "sentinel filter added: dev ${OVERLAY} egress prio ${SENTINEL_PRIO} handle ${SENTINEL_HANDLE}"

    "${VT_BIN}" \
        --overlay "${OVERLAY}" \
        --underlay "${UNDERLAY}" \
        --bpf-dir "${BPF_DIR}" \
        --pin-dir "${PIN_DIR}" \
        --duration 2s \
        >/dev/null 2>&1

    assert_filter_exists "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${OVERLAY}" egress "B"
    assert_no_vt_filter "${OVERLAY}" egress "B"
    assert_maps_cleaned "B"

    tc filter del dev "${OVERLAY}" egress prio "${SENTINEL_PRIO}" 2>/dev/null || true
else
    _skip "B: could not add sentinel filter"
fi

# ── Case C: Priority collision — vt must not remove a non-owned filter ─────────

_hdr "C — priority collision: non-owned filter at vt's priority"

# Add a matchall filter at EXACTLY vxlan-tracer's priority (50000) but with a
# DIFFERENT handle (not 0x76740001). vxlan-tracer must not delete it and must
# either use an alternate slot or fail cleanly.
COLLISION_HANDLE="0xc0de"
if add_sentinel_filter 50000 "${COLLISION_HANDLE}" "${UNDERLAY}" ingress; then
    _info "collision filter added: dev ${UNDERLAY} ingress prio 50000 handle ${COLLISION_HANDLE}"

    # vxlan-tracer may succeed (alternate slot) or fail (clear error).
    # Either way, the collision filter must survive.
    "${VT_BIN}" \
        --overlay "${OVERLAY}" \
        --underlay "${UNDERLAY}" \
        --bpf-dir "${BPF_DIR}" \
        --pin-dir "${PIN_DIR}" \
        --duration 1s \
        >/dev/null 2>&1 || true  # failure is acceptable here

    # Verify the collision filter still exists.
    found=$(tc filter show dev "${UNDERLAY}" ingress prio 50000 2>/dev/null \
            | grep -c "${COLLISION_HANDLE}" || true)
    if [[ "${found}" -ge 1 ]]; then
        _pass "C: collision filter survived (handle ${COLLISION_HANDLE} not deleted)"
    else
        _fail "C: collision filter was DELETED — handle ${COLLISION_HANDLE} at prio 50000"
    fi

    tc filter del dev "${UNDERLAY}" ingress prio 50000 handle "${COLLISION_HANDLE}" \
        matchall 2>/dev/null || true
else
    _skip "C: could not add collision filter"
fi

# ── Case D: Partial attach failure — rollback removes only vt resources ────────

_hdr "D — partial attach failure rollback"

# We cannot easily force a partial BPF load failure in a portable way without
# modifying the binary. Instead, we verify that after a FAILED run (BPF objects
# do not exist), no TC state is left behind.
BOGUS_BPF_DIR="/tmp/vt-nonexistent-bpf-$$"
# (do not create it — guaranteed fail)

# Add a sentinel before the attempted run.
if add_sentinel_filter "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress; then
    "${VT_BIN}" \
        --overlay "${OVERLAY}" \
        --underlay "${UNDERLAY}" \
        --bpf-dir "${BOGUS_BPF_DIR}" \
        --pin-dir "${PIN_DIR}" \
        --duration 1s \
        >/dev/null 2>&1 || true  # expected to fail

    # The sentinel must survive even though vt tried to attach (and failed).
    assert_filter_exists "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress "D"

    # No vxlan-tracer filter should remain (failed attach = no filter added).
    assert_no_vt_filter "${UNDERLAY}" ingress "D"
    assert_maps_cleaned "D"

    tc filter del dev "${UNDERLAY}" ingress prio "${SENTINEL_PRIO}" 2>/dev/null || true
else
    _skip "D: could not add sentinel filter for rollback test"
fi

# ── Case E: Signal cleanup (SIGINT, SIGTERM) ──────────────────────────────────

_hdr "E — signal cleanup (SIGINT + SIGTERM)"

# E1: SIGINT
if add_sentinel_filter "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress; then
    VT_PID=$(run_vt_bg)
    _info "E1: launched vxlan-tracer PID ${VT_PID}; sleeping 0.5s then sending SIGINT"
    sleep 0.5
    kill -INT "${VT_PID}" 2>/dev/null || true
    wait "${VT_PID}" 2>/dev/null || true
    sleep 0.2  # allow cleanup

    assert_filter_exists "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress "E1/SIGINT"
    assert_no_vt_filter "${UNDERLAY}" ingress "E1/SIGINT"
    assert_maps_cleaned "E1/SIGINT"

    tc filter del dev "${UNDERLAY}" ingress prio "${SENTINEL_PRIO}" 2>/dev/null || true
    rm -f /run/vxlan-tracer.lock
else
    _skip "E1: cannot add sentinel filter"
fi

# E2: SIGTERM
if add_sentinel_filter "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress; then
    VT_PID=$(run_vt_bg)
    _info "E2: launched vxlan-tracer PID ${VT_PID}; sleeping 0.5s then sending SIGTERM"
    sleep 0.5
    kill -TERM "${VT_PID}" 2>/dev/null || true
    wait "${VT_PID}" 2>/dev/null || true
    sleep 0.2

    assert_filter_exists "${SENTINEL_PRIO}" "${SENTINEL_HANDLE}" "${UNDERLAY}" ingress "E2/SIGTERM"
    assert_no_vt_filter "${UNDERLAY}" ingress "E2/SIGTERM"
    assert_maps_cleaned "E2/SIGTERM"

    tc filter del dev "${UNDERLAY}" ingress prio "${SENTINEL_PRIO}" 2>/dev/null || true
    rm -f /run/vxlan-tracer.lock
else
    _skip "E2: cannot add sentinel filter"
fi

# ── Case F: Repeated runs succeed; no stale state between runs ────────────────

_hdr "F — repeated runs without manual cleanup"

RUN1_EXIT=0
RUN2_EXIT=0

"${VT_BIN}" \
    --overlay "${OVERLAY}" \
    --underlay "${UNDERLAY}" \
    --bpf-dir "${BPF_DIR}" \
    --pin-dir "${PIN_DIR}" \
    --duration 1s \
    >/dev/null 2>&1 || RUN1_EXIT=$?

_info "run 1 exit code: ${RUN1_EXIT}"

"${VT_BIN}" \
    --overlay "${OVERLAY}" \
    --underlay "${UNDERLAY}" \
    --bpf-dir "${BPF_DIR}" \
    --pin-dir "${PIN_DIR}" \
    --duration 1s \
    >/dev/null 2>&1 || RUN2_EXIT=$?

_info "run 2 exit code: ${RUN2_EXIT}"

if [[ ${RUN1_EXIT} -eq 0 && ${RUN2_EXIT} -eq 0 ]]; then
    _pass "F: both runs exited 0"
else
    _fail "F: one or both runs failed (run1=${RUN1_EXIT}, run2=${RUN2_EXIT})"
fi
assert_no_vt_filter "${UNDERLAY}" ingress "F/after-run2"
assert_no_vt_filter "${OVERLAY}" egress "F/after-run2"
assert_maps_cleaned "F/after-run2"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== TC coexistence test summary ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  SKIP: ${SKIP}"
echo ""
if [[ ${FAIL} -gt 0 ]]; then
    echo "RESULT: FAIL"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
