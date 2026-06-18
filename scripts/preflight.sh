#!/usr/bin/env bash
# scripts/preflight.sh
#
# Pre-flight check for vxlan-tracer.
# Verifies all runtime requirements before attempting BPF load or lab setup.
#
# Usage:
#   bash scripts/preflight.sh
#   sudo bash scripts/preflight.sh   (required for bpffs and capability checks)
#
# Exit codes:
#   0  all checks PASS
#   1  one or more checks FAIL (see output for details)

set -uo pipefail

PASS=0
FAIL=0
WARN=0

_pass() { echo "  PASS  $*"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL  $*" >&2; FAIL=$((FAIL+1)); }
_warn() { echo "  WARN  $*"; WARN=$((WARN+1)); }
_info() { echo "  INFO  $*"; }

echo ""
echo "=== vxlan-tracer preflight check ==="
echo ""

# --- OS and kernel ---
echo "-- OS / Kernel --"
_info "$(uname -a)"

if [[ "$(uname -s)" != "Linux" ]]; then
    _fail "Not running on Linux (uname -s = $(uname -s)). vxlan-tracer requires Linux."
else
    _pass "Linux"
fi

KVER="$(uname -r)"
KMAJ=$(echo "$KVER" | cut -d. -f1)
KMIN=$(echo "$KVER" | cut -d. -f2)
if [[ "$KMAJ" -gt 5 ]] || { [[ "$KMAJ" -eq 5 ]] && [[ "$KMIN" -ge 15 ]]; }; then
    _pass "Kernel $KVER >= 5.15 (CO-RE/BTF required minimum)"
else
    _fail "Kernel $KVER < 5.15 — BTF/CO-RE may not be available. Upgrade required."
fi

# --- Root / capabilities ---
echo ""
echo "-- Privileges --"
if [[ $EUID -eq 0 ]]; then
    _pass "Running as root"
else
    _warn "Not running as root. BPF load and netns operations require root or CAP_BPF+CAP_NET_ADMIN."
fi

# --- BTF ---
echo ""
echo "-- BTF (CO-RE prerequisite) --"
if [[ -f /sys/kernel/btf/vmlinux ]]; then
    BTF_SIZE=$(wc -c < /sys/kernel/btf/vmlinux 2>/dev/null || echo 0)
    _pass "/sys/kernel/btf/vmlinux exists (${BTF_SIZE} bytes)"
else
    _fail "/sys/kernel/btf/vmlinux not found. CO-RE BPF programs will not load."
    _info "  Fix: use a kernel with CONFIG_DEBUG_INFO_BTF=y (Ubuntu 20.04+ ships this)"
fi

# --- bpffs ---
echo ""
echo "-- bpffs --"
if mount | grep -q 'type bpf'; then
    _pass "bpffs mounted ($(mount | grep 'type bpf' | awk '{print $3}'))"
elif [[ -d /sys/fs/bpf ]]; then
    _warn "/sys/fs/bpf exists but bpffs may not be mounted. Attempting mount check..."
    if [[ $EUID -eq 0 ]]; then
        mount -t bpf bpf /sys/fs/bpf 2>/dev/null \
            && _pass "bpffs mounted at /sys/fs/bpf" \
            || _warn "bpffs mount attempt failed (may already be mounted differently)"
    else
        _warn "Cannot mount bpffs without root. Run: sudo mount -t bpf bpf /sys/fs/bpf"
    fi
else
    _fail "/sys/fs/bpf does not exist. Run: sudo bash scripts/setup-bpf-fs.sh"
fi

# --- Required commands ---
echo ""
echo "-- Required commands --"
for cmd in ip iptables python3 nsenter; do
    if command -v "$cmd" &>/dev/null; then
        _pass "$cmd ($(command -v "$cmd"))"
    else
        _fail "$cmd not found. Install: apt-get install -y iproute2 iptables python3"
    fi
done

echo ""
echo "-- Build tools --"
for cmd in clang go make; do
    if command -v "$cmd" &>/dev/null; then
        _pass "$cmd ($("$cmd" --version 2>/dev/null | head -1 || echo 'version unknown'))"
    else
        _fail "$cmd not found."
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
    _warn "bpftool not found (optional; used for map inspection). apt-get install linux-tools-$(uname -r)"
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
    _fail "python3 scapy not found. Run: pip3 install scapy"
fi

# --- libbpf headers ---
echo ""
echo "-- libbpf headers (BPF compilation) --"
if [[ -f /usr/include/bpf/bpf_helpers.h ]]; then
    _pass "/usr/include/bpf/bpf_helpers.h found"
else
    _fail "libbpf headers not found. Run: apt-get install -y libbpf-dev"
fi
if [[ -f /usr/include/linux/bpf.h ]]; then
    _pass "/usr/include/linux/bpf.h found"
else
    _fail "Linux UAPI headers not found. Run: apt-get install -y linux-libc-dev"
fi

# --- kernel symbols ---
echo ""
echo "-- Kernel symbols (kprobe targets) --"
if [[ -f /proc/kallsyms ]]; then
    if grep -q ' T ip_do_fragment$' /proc/kallsyms; then
        _pass "ip_do_fragment is a T symbol (kprobeable)"
    else
        _fail "ip_do_fragment not found as T symbol in /proc/kallsyms"
        _info "  ip_do_fragment may be inlined in this kernel — kprobe will not attach"
    fi
    if grep -q ' T icmp_rcv$' /proc/kallsyms; then
        _pass "icmp_rcv is a T symbol (kprobeable)"
    else
        _fail "icmp_rcv not found as T symbol in /proc/kallsyms"
    fi
else
    _warn "/proc/kallsyms not readable (may need root)"
fi

# --- ip netns ---
echo ""
echo "-- Network namespace support --"
if ip netns list &>/dev/null; then
    _pass "ip netns works"
else
    _fail "ip netns failed — iproute2 may be missing or insufficient privileges"
fi

echo ""
echo "==================================="
echo "Preflight summary:"
echo "  PASS: $PASS"
echo "  WARN: $WARN"
echo "  FAIL: $FAIL"
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
