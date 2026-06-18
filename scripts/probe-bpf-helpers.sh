#!/usr/bin/env bash
# scripts/probe-bpf-helpers.sh
#
# Probes BPF helper availability for kprobe and sched_cls program types
# on the current kernel. Compiles minimal BPF programs that call the
# target helper and attempts to load them via the BPF syscall.
#
# Requirements: Linux, root, clang, cilium/ebpf Go binary (probe_helper)
#
# Usage:
#   PROBE_BINARY=/path/to/probe_helper bash scripts/probe-bpf-helpers.sh
#
# Exit codes:
#   0  all tested helpers supported in all tested program types
#   1  one or more helpers unsupported

set -uo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: BPF programs require Linux." >&2
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root (BPF_PROG_LOAD requires CAP_BPF)." >&2
    exit 1
fi

WORK_DIR="${WORK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BPF_DIR="${BPF_DIR:-/tmp/bpf-probe-objs}"
PROBE_BINARY="${PROBE_BINARY:-/tmp/probe_helper_linux_arm64}"

mkdir -p "$BPF_DIR"

echo "=== BPF Helper Probe ==="
echo "  Kernel: $(uname -r) $(uname -m)"
echo "  Work dir: $WORK_DIR"

echo ""
echo "--- bpf_get_netns_cookie probe ---"

# Compile kprobe probe
echo "  Compiling kprobe probe..."
_ARCH_INC=""
if [[ "$(uname -m)" == "aarch64" ]]; then
    _ARCH_INC="-I/usr/include/aarch64-linux-gnu -D__TARGET_ARCH_arm64"
elif [[ "$(uname -m)" == "x86_64" ]]; then
    _ARCH_INC="-I/usr/include/x86_64-linux-gnu -D__TARGET_ARCH_x86"
fi

clang -O2 -g -target bpf -I/usr/include $_ARCH_INC \
    -Wall -Wno-unused-value -Wno-pointer-sign \
    -c "$WORK_DIR/spikes/probe_netns_cookie_kprobe.bpf.c" \
    -o "$BPF_DIR/probe_netns_cookie_kprobe.bpf.o" 2>&1 | sed 's/^/    /'
KPROBE_COMPILE=${PIPESTATUS[0]}
echo "  kprobe compile: exit=$KPROBE_COMPILE"

# Compile sched_cls probe
echo "  Compiling sched_cls probe..."
clang -O2 -g -target bpf -I/usr/include \
    -I"${_ARCH_INC#-I}" 2>/dev/null \
    -Wall -Wno-unused-value -Wno-pointer-sign \
    -c "$WORK_DIR/spikes/probe_netns_cookie_cls.bpf.c" \
    -o "$BPF_DIR/probe_netns_cookie_cls.bpf.o" 2>&1 | sed 's/^/    /'
CLS_COMPILE=${PIPESTATUS[0]}
# Simpler compile for cls (no arch define needed)
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
    -Wall -Wno-unused-value -Wno-pointer-sign \
    -c "$WORK_DIR/spikes/probe_netns_cookie_cls.bpf.c" \
    -o "$BPF_DIR/probe_netns_cookie_cls.bpf.o" 2>&1 | sed 's/^/    /'
CLS_COMPILE=$?
echo "  sched_cls compile: exit=$CLS_COMPILE"

if [[ -x "$PROBE_BINARY" ]]; then
    echo ""
    echo "  Running Go loader probe..."
    "$PROBE_BINARY" \
        --kprobe "$BPF_DIR/probe_netns_cookie_kprobe.bpf.o" \
        --cls "$BPF_DIR/probe_netns_cookie_cls.bpf.o" 2>&1 | sed 's/^/  /'
    PROBE_EXIT=$?
else
    echo "  PROBE_BINARY not found at $PROBE_BINARY — skipping load test"
    PROBE_EXIT=99
fi

echo ""
echo "--- /proc/kallsyms: bpf_get_netns_cookie wrappers ---"
echo "  (presence indicates which program types may call this helper)"
grep "bpf_get_netns_cookie" /proc/kallsyms 2>/dev/null | awk '{print "  " $3}' | sort \
    || echo "  (not found — helper may be absent or kallsyms not readable)"

echo ""
echo "=== Done ==="
echo "  exit code: $PROBE_EXIT"
exit $PROBE_EXIT
