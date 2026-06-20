#!/usr/bin/env bash
# scripts/preflight.sh
#
# Pre-flight check for vxlan-tracer.
# Verifies all runtime requirements before attempting BPF load or lab setup.
#
# Failure categories:
#   [DEPENDENCY]   — tool or file missing; fix with apt-get install or similar
#   [PRIVILEGE]    — operation requires more capability/root
#   [KERNEL]       — kernel feature absent or version too old
#   [ENVIRONMENT]  — host restriction (shared runner, container, etc.)
#
# Usage:
#   sudo bash scripts/preflight.sh   (root required for capability and BPF checks)
#
# Exit codes:
#   0  all checks PASS (possibly with warnings)
#   1  one or more checks FAIL

set -uo pipefail

PASS=0
FAIL=0
WARN=0

_pass() { echo "  PASS        $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL [$1]  ${*:2}" >&2; FAIL=$((FAIL+1)); }
_warn() { echo "  WARN        $*"; WARN=$((WARN+1)); }
_info() { echo "  INFO        $*"; }

echo ""
echo "=== vxlan-tracer preflight check ==="
echo ""

# --- OS and kernel ---
echo "-- OS / Kernel --"
_info "$(uname -a)"

if [[ "$(uname -s)" != "Linux" ]]; then
    _fail "KERNEL" "Not running on Linux (uname -s = $(uname -s)). vxlan-tracer requires Linux."
else
    _pass "Linux"
    _info "arch: $(uname -m)"
fi

KVER="$(uname -r)"
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2 | cut -d- -f1)
if [[ "$KMAJ" -gt 5 ]] || { [[ "$KMAJ" -eq 5 ]] && [[ "$KMIN" -ge 15 ]]; }; then
    _pass "Kernel $KVER >= 5.15 (CO-RE/BTF required minimum)"
else
    _fail "KERNEL" "Kernel $KVER < 5.15 — BTF/CO-RE may not be available."
fi

# --- Privileges and capabilities ---
echo ""
echo "-- Privileges / Capabilities --"
if [[ $EUID -eq 0 ]]; then
    _pass "Running as root (UID 0)"
else
    _fail "PRIVILEGE" "Not running as root. BPF load and netns operations require root."
    _info "  Run: sudo bash scripts/preflight.sh"
fi

# Check unprivileged BPF restriction
if [[ -f /proc/sys/kernel/unprivileged_bpf_disabled ]]; then
    BPF_RESTRICT=$(cat /proc/sys/kernel/unprivileged_bpf_disabled)
    case "$BPF_RESTRICT" in
        0) _pass "unprivileged_bpf_disabled=0 (BPF unrestricted)" ;;
        1) _warn "unprivileged_bpf_disabled=1 (unprivileged BPF restricted; root required)" ;;
        2) _warn "unprivileged_bpf_disabled=2 (BPF restricted even with CAP_BPF in some contexts)" ;;
        *) _warn "unprivileged_bpf_disabled=$BPF_RESTRICT (unknown value)" ;;
    esac
else
    _warn "unprivileged_bpf_disabled not found (older kernel or not exposed)"
fi

# Check perf_event_paranoia (affects kprobe via perf on some kernels)
if [[ -f /proc/sys/kernel/perf_event_paranoid ]]; then
    PERF_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid)
    if [[ "$PERF_PARANOID" -le 2 ]]; then
        _pass "perf_event_paranoid=$PERF_PARANOID (kprobes accessible to root)"
    else
        _warn "perf_event_paranoid=$PERF_PARANOID (kprobes may be restricted; typically fine for root)"
    fi
fi

# Probe: can we create a network namespace?
echo ""
echo "-- Network namespace capability probe --"
_NS_TEST="preflight-test-$$"
if ip netns add "$_NS_TEST" 2>/dev/null; then
    ip netns del "$_NS_TEST" 2>/dev/null
    _pass "ip netns add/del works (CAP_NET_ADMIN present)"
elif [[ $EUID -eq 0 ]]; then
    _fail "ENVIRONMENT" "ip netns add failed even as root — kernel may restrict user namespaces or iproute2 broken"
else
    _fail "PRIVILEGE" "ip netns add failed — requires root"
fi

# Probe: can we add a clsact qdisc to a global-namespace dummy interface?
# This probe uses a temporary dummy interface in the default network namespace.
# vxlan-tracer itself creates clsact qdiscs on veth interfaces INSIDE network
# namespaces (see setup-netns.sh), so a failure here does not prevent scenarios
# from running.  GitHub-hosted ubuntu-22.04 runners block ip link add dummy in
# the global namespace even as root — this is an environment restriction, not a
# vxlan-tracer requirement.  Demoted to WARN.
echo ""
echo "-- clsact qdisc capability probe (global netns; informational only) --"
_DUMMY="preflight-veth-$$"
if ip link add "$_DUMMY" type dummy 2>/dev/null; then
    if ip link set dev "$_DUMMY" up 2>/dev/null && \
       tc qdisc add dev "$_DUMMY" clsact 2>/dev/null; then
        _pass "clsact qdisc on dummy interface works (CAP_NET_ADMIN + TC BPF available)"
    else
        _warn "dummy interface created but clsact qdisc failed (TC BPF may be restricted)"
    fi
    ip link del "$_DUMMY" 2>/dev/null || true
elif [[ $EUID -eq 0 ]]; then
    _warn "ip link add dummy restricted in this environment (shared runner or unprivileged container)"
    _info "  vxlan-tracer uses veth interfaces inside netns — this probe is not a hard requirement"
else
    _fail "PRIVILEGE" "ip link add dummy failed — requires root"
fi

# Probe: BPF map creation via bpftool (if available)
echo ""
echo "-- BPF map creation probe --"
_BPF_MAP_PIN="/sys/fs/bpf/preflight-test-map-$$"
if command -v bpftool &>/dev/null; then
    if bpftool map create "$_BPF_MAP_PIN" type array key 4 value 8 entries 1 \
            name preflight 2>/dev/null; then
        rm -f "$_BPF_MAP_PIN" 2>/dev/null
        _pass "BPF ARRAY map create via bpftool works (CAP_BPF present)"
    else
        _fail "ENVIRONMENT" "BPF map create failed (CAP_BPF missing or bpffs not mounted)"
        _info "  bpftool err: $(bpftool map create "$_BPF_MAP_PIN" type array key 4 value 8 entries 1 name preflight 2>&1 | head -3)"
        rm -f "$_BPF_MAP_PIN" 2>/dev/null
    fi
else
    _warn "bpftool not found — cannot probe BPF map creation directly"
    _info "  bpftool install: apt-get install linux-tools-\$(uname -r)"
fi

# --- BTF ---
echo ""
echo "-- BTF (CO-RE prerequisite) --"
if [[ -f /sys/kernel/btf/vmlinux ]]; then
    BTF_SIZE=$(wc -c < /sys/kernel/btf/vmlinux 2>/dev/null || echo 0)
    _pass "/sys/kernel/btf/vmlinux exists (${BTF_SIZE} bytes)"
else
    _fail "KERNEL" "/sys/kernel/btf/vmlinux not found. CO-RE BPF programs will not load."
    _info "  Fix: use a kernel with CONFIG_DEBUG_INFO_BTF=y (Ubuntu 20.04+ ships this)"
fi

# --- bpffs ---
echo ""
echo "-- bpffs --"
if mount | grep -q 'type bpf'; then
    _pass "bpffs mounted ($(mount | grep 'type bpf' | head -1 | awk '{print $3}'))"
elif [[ -d /sys/fs/bpf ]]; then
    if [[ $EUID -eq 0 ]]; then
        mount -t bpf bpf /sys/fs/bpf 2>/dev/null \
            && _pass "bpffs mounted at /sys/fs/bpf" \
            || _fail "ENVIRONMENT" "bpffs mount failed (may be restricted in this environment)"
    else
        _fail "PRIVILEGE" "bpffs not mounted; cannot mount without root"
    fi
else
    _fail "DEPENDENCY" "/sys/fs/bpf does not exist. Run: sudo bash scripts/setup-bpf-fs.sh"
fi

# --- Required commands ---
echo ""
echo "-- Required commands --"
for cmd in ip iptables python3 nsenter; do
    if command -v "$cmd" &>/dev/null; then
        _pass "$cmd ($(command -v "$cmd"))"
    else
        _fail "DEPENDENCY" "$cmd not found."
        case "$cmd" in
            ip|iptables) _info "  Fix: apt-get install -y iproute2 iptables" ;;
            python3)     _info "  Fix: apt-get install -y python3" ;;
            nsenter)     _info "  Fix: apt-get install -y util-linux" ;;
        esac
    fi
done

echo ""
echo "-- Build tools --"
for cmd in clang go make; do
    if command -v "$cmd" &>/dev/null; then
        _pass "$cmd ($("$cmd" --version 2>/dev/null | head -1 || echo 'version unknown'))"
    else
        _fail "DEPENDENCY" "$cmd not found."
        case "$cmd" in
            clang) _info "  Fix: apt-get install -y clang llvm libbpf-dev" ;;
            go)    _info "  Fix: see https://go.dev/dl/ or docs/vm-validation.md" ;;
            make)  _info "  Fix: apt-get install -y make" ;;
        esac
    fi
done

echo ""
echo "-- Optional tools --"
if command -v bpftool &>/dev/null; then
    _pass "bpftool ($( bpftool version 2>/dev/null | head -1 || echo 'version unknown'))"
else
    _warn "bpftool not found (optional; used for map inspection and capability probe)"
    _info "  Install: apt-get install linux-tools-\$(uname -r)"
fi
if command -v ping &>/dev/null; then
    _pass "ping ($(command -v ping))"
else
    _warn "ping not found. apt-get install -y iputils-ping"
fi

# --- scapy ---
echo ""
echo "-- Python scapy (PTB injection) --"
if python3 -c "import scapy" 2>/dev/null; then
    SCAPY_VER=$(python3 -c "import scapy; print(scapy.__version__)" 2>/dev/null || echo "unknown")
    _pass "scapy $SCAPY_VER"
else
    _fail "DEPENDENCY" "python3 scapy not found. Run: pip3 install scapy"
fi

# --- libbpf headers ---
echo ""
echo "-- libbpf headers (BPF compilation) --"
if [[ -f /usr/include/bpf/bpf_helpers.h ]]; then
    _pass "/usr/include/bpf/bpf_helpers.h found"
else
    _fail "DEPENDENCY" "libbpf headers not found. Run: apt-get install -y libbpf-dev"
fi
if [[ -f /usr/include/linux/bpf.h ]]; then
    _pass "/usr/include/linux/bpf.h found"
else
    _fail "DEPENDENCY" "Linux UAPI headers not found. Run: apt-get install -y linux-libc-dev"
fi

# --- Architecture-specific include path ---
echo ""
echo "-- Architecture-specific BPF compile path --"
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64)
        ARCH_INC="/usr/include/aarch64-linux-gnu"
        ARCH_DEF="__TARGET_ARCH_arm64"
        ;;
    x86_64)
        ARCH_INC="/usr/include/x86_64-linux-gnu"
        ARCH_DEF="__TARGET_ARCH_x86"
        ;;
    *)
        ARCH_INC=""
        ARCH_DEF="(unsupported)"
        ;;
esac
_info "arch=$ARCH → BPF define: -D$ARCH_DEF"
if [[ -n "$ARCH_INC" ]] && [[ -d "$ARCH_INC" ]]; then
    _pass "arch include path: $ARCH_INC (exists)"
elif [[ -n "$ARCH_INC" ]]; then
    _fail "DEPENDENCY" "arch include path missing: $ARCH_INC"
    _info "  Fix: apt-get install -y gcc-multilib or libc6-dev-i386"
else
    _fail "KERNEL" "Unsupported architecture: $ARCH (only aarch64 and x86_64 are supported)"
fi

# --- kernel symbols ---
echo ""
echo "-- Kernel symbols (kprobe targets) --"
if [[ -f /proc/kallsyms ]]; then
    if grep -q ' T ip_do_fragment$' /proc/kallsyms; then
        _pass "ip_do_fragment is a T symbol (kprobeable)"
    else
        _fail "KERNEL" "ip_do_fragment not found as T symbol in /proc/kallsyms"
        _info "  ip_do_fragment may be inlined in this kernel — kprobe will not attach"
    fi
    if grep -q ' T icmp_rcv$' /proc/kallsyms; then
        _pass "icmp_rcv is a T symbol (kprobeable)"
    else
        _fail "KERNEL" "icmp_rcv not found as T symbol in /proc/kallsyms"
    fi
else
    _warn "KERNEL" "/proc/kallsyms not readable (may need root)"
fi

# --- ip netns list (basic test, separate from probe above) ---
echo ""
echo "-- Network namespace support --"
if ip netns list &>/dev/null; then
    _pass "ip netns list works"
else
    _fail "PRIVILEGE" "ip netns list failed — iproute2 missing or insufficient privileges"
fi

# --- BPF object freshness (optional — skipped if objects not compiled yet) ---
echo ""
echo "-- BPF object freshness (vxlan_config map) --"
_INGRESS_OBJ="${BPF_DIR:-bpf}/tc_ingress_eth0.bpf.o"
if [[ -f "$_INGRESS_OBJ" ]]; then
    _ingress_size=$(wc -c < "$_INGRESS_OBJ" 2>/dev/null || echo 0)
    _info "$_INGRESS_OBJ exists ($_ingress_size bytes)"
    # Check for the vxlan_config symbol in the ELF object.
    # vxlan_config is a symbol in the .maps section (not a section itself).
    # Use readelf -s (symbol table, lowercase -s) or nm.
    _found_cfg=0
    if readelf -s "$_INGRESS_OBJ" 2>/dev/null | grep -q vxlan_config; then
        _found_cfg=1
    elif nm "$_INGRESS_OBJ" 2>/dev/null | grep -q vxlan_config; then
        _found_cfg=1
    elif strings "$_INGRESS_OBJ" 2>/dev/null | grep -qx vxlan_config; then
        _found_cfg=1
    fi
    if [[ $_found_cfg -eq 1 ]]; then
        _pass "$_INGRESS_OBJ contains vxlan_config map section (object is fresh)"
    else
        _fail "DEPENDENCY" "$_INGRESS_OBJ is missing the vxlan_config section — stale object"
        _info "  Fix: make clean-bpf && make bpf"
    fi
else
    _info "$_INGRESS_OBJ not found — BPF objects not compiled yet (run 'make bpf')"
fi

echo ""
echo "==================================="
echo "Preflight summary:"
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"
echo ""
echo "Failure categories explained:"
echo "  [DEPENDENCY]   — install missing package"
echo "  [PRIVILEGE]    — re-run as root (sudo)"
echo "  [KERNEL]       — kernel too old, feature absent, or symbol inlined"
echo "  [ENVIRONMENT]  — host/runner restriction (shared CI, unprivileged container)"
echo "==================================="

if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: FAIL — fix the items above before running scenarios."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo "RESULT: PASS with warnings — review warnings above."
    exit 0
else
    echo "RESULT: PASS — all checks passed."
    exit 0
fi
