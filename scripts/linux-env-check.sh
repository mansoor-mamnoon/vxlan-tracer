#!/usr/bin/env bash
# scripts/linux-env-check.sh
#
# Pre-flight environment check for vxlan-tracer development/testing.
# Prints PASS/WARN/FAIL for each requirement.
# Must run as root for full symbol and privilege checks.

set -uo pipefail

PASS=0
WARN=0
FAIL=0

_pass() { echo "  [PASS] $*"; PASS=$((PASS+1)); }
_warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
_fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "=== vxlan-tracer Linux environment check ==="
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# ---- 1. OS check ----
echo "[1] Operating system"
KERNEL=$(uname -r 2>/dev/null || echo "unknown")
OS=$(uname -s 2>/dev/null || echo "unknown")
echo "    uname -a: $(uname -a 2>/dev/null)"
if [[ "$OS" != "Linux" ]]; then
    _fail "Not Linux (got: $OS). All kernel-level features require Linux."
else
    # Parse major.minor kernel version
    KMAJOR=$(echo "$KERNEL" | cut -d. -f1)
    KMINOR=$(echo "$KERNEL" | cut -d. -f2 | grep -oP '^\d+')
    if [[ $KMAJOR -gt 5 ]] || [[ $KMAJOR -eq 5 && $KMINOR -ge 15 ]]; then
        _pass "Linux $KERNEL (>= 5.15 recommended)"
    elif [[ $KMAJOR -eq 5 && $KMINOR -ge 10 ]]; then
        _warn "Linux $KERNEL (5.10+ supported, 5.15+ recommended for fentry/BTF)"
    else
        _fail "Linux $KERNEL too old (need 5.10+; fentry requires 5.5+; BTF requires 5.4+)"
    fi
fi
echo ""

# ---- 2. Privilege check ----
echo "[2] Privilege"
if [[ $EUID -eq 0 ]]; then
    _pass "Running as root"
else
    _fail "Not root. BPF attachment and netns creation require root / CAP_BPF + CAP_NET_ADMIN."
fi
echo ""

# ---- 3. /proc/kallsyms ----
echo "[3] /proc/kallsyms availability"
if [[ -r /proc/kallsyms ]]; then
    _pass "/proc/kallsyms readable ($(wc -l < /proc/kallsyms) symbols)"
else
    _fail "/proc/kallsyms not readable — cannot verify kernel symbols"
fi
echo ""

# ---- 4. BTF / vmlinux ----
echo "[4] BTF (vmlinux type info)"
if [[ -f /sys/kernel/btf/vmlinux ]]; then
    SIZE=$(wc -c < /sys/kernel/btf/vmlinux)
    _pass "/sys/kernel/btf/vmlinux exists (${SIZE} bytes) — fentry programs supported"
else
    _warn "/sys/kernel/btf/vmlinux not found — fentry programs will not work; fall back to kprobe"
fi
echo ""

# ---- 5. Required kernel symbols ----
echo "[5] Required kernel symbols"
check_symbol() {
    local sym="$1" required="$2"
    if [[ ! -r /proc/kallsyms ]]; then
        _warn "Cannot check $sym (kallsyms not readable)"
        return
    fi
    if grep -qE "^[0-9a-f]+ [Tt] ${sym}$" /proc/kallsyms 2>/dev/null; then
        local addr
        addr=$(grep -E "^[0-9a-f]+ [Tt] ${sym}$" /proc/kallsyms | head -1 | awk '{print $1}')
        _pass "$sym found at 0x$addr"
    else
        if [[ "$required" == "required" ]]; then
            _fail "$sym NOT FOUND in /proc/kallsyms — this hook will not work"
        else
            _warn "$sym not found — may be inlined; consider fallback hook"
        fi
    fi
}

check_symbol "ip_do_fragment"       "optional"  # may be inlined; __ip_finish_output is fallback
check_symbol "__ip_finish_output"   "optional"  # fallback for ip_do_fragment
check_symbol "icmp_send"            "required"
check_symbol "icmp_rcv"             "required"
check_symbol "icmp_unreach"         "optional"  # called by icmp_rcv; useful for tracing
echo ""

# ---- 6. Tools ----
echo "[6] Required tools"
check_tool() {
    local cmd="$1" minver="$2"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "version unknown")
        _pass "$cmd found: $ver"
    else
        _fail "$cmd not found (needed: $minver)"
    fi
}
check_tool "bpftool"  "kernel-matched"
check_tool "bpftrace" "0.16+"
check_tool "clang"    "12+"
check_tool "ip"       "iproute2"
check_tool "python3"  "3.8+"
echo ""

# ---- 7. Optional but useful tools ----
echo "[7] Optional tools"
for cmd in iptables nft curl ping tcpdump; do
    if command -v "$cmd" &>/dev/null; then
        _pass "$cmd found"
    else
        _warn "$cmd not found (optional but useful for lab)"
    fi
done
echo ""

# ---- 8. Network namespace support ----
echo "[8] Network namespace support"
if ip netns list &>/dev/null; then
    _pass "ip netns works"
else
    _fail "ip netns failed — iproute2 or kernel CONFIG_NET_NS may be missing"
fi
echo ""

# ---- 9. BPF syscall availability ----
echo "[9] BPF syscall"
if bpftool prog list &>/dev/null 2>&1; then
    PROG_COUNT=$(bpftool prog list 2>/dev/null | grep -c "^[0-9]" || echo 0)
    _pass "bpftool prog list works ($PROG_COUNT programs currently loaded)"
elif [[ -f /proc/sys/kernel/unprivileged_bpf_disabled ]]; then
    VAL=$(cat /proc/sys/kernel/unprivileged_bpf_disabled)
    _warn "bpftool not found; /proc/sys/kernel/unprivileged_bpf_disabled=$VAL"
else
    _warn "Cannot verify BPF syscall (bpftool not installed)"
fi
echo ""

# ---- 10. scapy (for PTB injection) ----
echo "[10] scapy (for synthetic PTB injection)"
if python3 -c "import scapy" &>/dev/null 2>&1; then
    VER=$(python3 -c "import scapy; print(scapy.__version__)" 2>/dev/null || echo "unknown")
    _pass "scapy $VER available"
else
    _warn "scapy not installed — PTB suppression spike will not work (pip3 install scapy)"
fi
echo ""

# ---- Summary ----
echo "=== Summary ==="
echo "  PASS : $PASS"
echo "  WARN : $WARN"
echo "  FAIL : $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: FAIL — $FAIL required checks failed. See above."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo "RESULT: WARN — environment usable with limitations. See warnings above."
    exit 0
else
    echo "RESULT: PASS — environment ready for vxlan-tracer development."
    exit 0
fi
