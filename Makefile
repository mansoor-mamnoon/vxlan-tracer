# vxlan-tracer build system
#
# BPF targets require Linux with clang, libbpf-dev, and linux-libc-dev.
# They will not work on macOS. The Go userspace binary builds on any platform.

BINARY := vxlan-tracer
CLANG  := clang

# Architecture-specific include path.
# On Ubuntu/Debian, asm/types.h lives under the arch triplet directory.
# clang (cross-compiling to BPF target) cannot locate it without -I.
# Confirmed required on aarch64 Docker linuxkit (June 2026).
_HOST_ARCH := $(shell uname -m 2>/dev/null || echo unknown)
ifeq ($(_HOST_ARCH),aarch64)
  _ARCH_INC := -I/usr/include/aarch64-linux-gnu
else ifeq ($(_HOST_ARCH),x86_64)
  _ARCH_INC := -I/usr/include/x86_64-linux-gnu
else
  _ARCH_INC :=
endif

# BPF compile flags for TC sched_cls programs.
# -D__TARGET_ARCH_* is absent: TC programs access packet data via struct
# __sk_buff and do not use arch-specific PT_REGS_PARM1 accessor macros.
CFLAGS_BPF := -O2 -g -target bpf \
              -I/usr/include \
              $(_ARCH_INC) \
              -Wall -Wno-unused-value -Wno-pointer-sign

# -D__TARGET_ARCH_* for kprobe programs that use PT_REGS_PARM1 to read the
# first function argument from the pt_regs context. bpf_tracing.h uses this
# define to select the correct register name for the host architecture.
ifeq ($(_HOST_ARCH),aarch64)
  _TARGET_ARCH_DEFINE := -D__TARGET_ARCH_arm64
else ifeq ($(_HOST_ARCH),x86_64)
  _TARGET_ARCH_DEFINE := -D__TARGET_ARCH_x86
else
  _TARGET_ARCH_DEFINE :=
endif

# Kprobe BPF flags: same as CFLAGS_BPF plus the target-arch define.
# Also uses CO-RE via preserve_access_index; no vmlinux.h needed —
# clang emits BTF relocations that libbpf resolves at load time.
CFLAGS_BPF_KPROBE := $(CFLAGS_BPF) $(_TARGET_ARCH_DEFINE)

PREFIX ?= /usr/local

.PHONY: all build build-linux-arm64 build-linux-amd64 package install uninstall \
        bpf bpf-check generate lint vet test preflight \
        lab-up lab-down smoke-small smoke-large scenarios cleanup-bpf \
        attach-bpf check-symbols clean help

all: build

# --- Go userspace binary ---
# build: native platform (whatever GOOS/GOARCH the host provides)
build: generate
	@mkdir -p dist
	go build -o dist/$(BINARY) ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)"

# build-linux-arm64: cross-compile for Linux/aarch64 (required for actual BPF execution)
build-linux-arm64: generate
	@mkdir -p dist
	GOOS=linux GOARCH=arm64 go build -o dist/$(BINARY)-linux-arm64 ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)-linux-arm64"

# build-linux-amd64: cross-compile for Linux/x86_64
build-linux-amd64: generate
	@mkdir -p dist
	GOOS=linux GOARCH=amd64 go build -o dist/$(BINARY)-linux-amd64 ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)-linux-amd64"

# package: build all Linux targets and create a release tarball under dist/
# BPF objects must be compiled separately on Linux (see make bpf).
package: build-linux-arm64 build-linux-amd64
	@mkdir -p dist/release
	@cp dist/$(BINARY)-linux-arm64 dist/release/
	@cp dist/$(BINARY)-linux-amd64 dist/release/
	@cp scripts/setup-bpf-fs.sh scripts/setup-netns.sh scripts/teardown-netns.sh \
	    scripts/cleanup-bpf.sh scripts/run-scenarios.sh dist/release/ 2>/dev/null || true
	@echo "Release files in dist/release/:"
	@ls -lh dist/release/

test:
	go test ./...

# preflight: check runtime requirements before attempting BPF load or lab setup.
# Requires Linux + root. Checks OS, kernel, BTF, bpffs, required commands, libbpf headers,
# kernel symbols, and scapy. Prints PASS/WARN/FAIL per check.
# Does not compile or load BPF; safe to run before 'make bpf'.
preflight:
	@sudo bash scripts/preflight.sh

# --- Install / Uninstall (Linux only) ---
# Installs the Go binary to PREFIX/bin. Does NOT install BPF objects
# (those must be compiled on Linux and passed via --bpf-dir at runtime).
# Does NOT install a systemd unit or daemon — vxlan-tracer is a one-shot CLI.
#
# Usage:
#   make install                        # installs to /usr/local/bin/
#   PREFIX=/tmp/vxlan-install make install  # installs to /tmp/vxlan-install/bin/
install:
	@if [ "$$(uname -s)" != "Linux" ]; then \
	    echo "ERROR: install target requires Linux (binary is Linux-only)"; exit 1; fi
	@mkdir -p "$(PREFIX)/bin"
	@ARCH="$$(uname -m)"; \
	if [ "$$ARCH" = "aarch64" ]; then SRC="dist/$(BINARY)-linux-arm64"; \
	elif [ "$$ARCH" = "x86_64" ]; then SRC="dist/$(BINARY)-linux-amd64"; \
	else echo "ERROR: unsupported arch $$ARCH"; exit 1; fi; \
	if [ ! -f "$$SRC" ]; then echo "ERROR: $$SRC not found; run make build-linux-arm64 or make build-linux-amd64 first"; exit 1; fi; \
	install -m 0755 "$$SRC" "$(PREFIX)/bin/$(BINARY)"; \
	echo "  installed: $(PREFIX)/bin/$(BINARY)"

uninstall:
	@rm -f "$(PREFIX)/bin/$(BINARY)"
	@echo "  removed: $(PREFIX)/bin/$(BINARY) (if it existed)"

generate:
	go generate ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./... 2>/dev/null || echo "golangci-lint not installed; skipping"

# --- BPF objects (Linux only) ---
bpf: bpf-check bpf/tc_ingress_eth0.bpf.o bpf/tc_egress_vxlan0.bpf.o bpf/kprobes.bpf.o bpf/frag_kprobes.bpf.o
	@echo "BPF build complete."
	@ls -lh bpf/*.bpf.o

bpf/tc_ingress_eth0.bpf.o: bpf/tc_ingress_eth0.bpf.c bpf/maps.h
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF) -c $< -o $@

bpf/tc_egress_vxlan0.bpf.o: bpf/tc_egress_vxlan0.bpf.c bpf/maps.h
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF) -c $< -o $@

# kprobes.bpf.c: icmp_rcv kprobe with CO-RE skb filtering (ICMP type=3/code=4).
# Needs __TARGET_ARCH_* for PT_REGS_PARM1; emits BTF relocations for skb fields.
bpf/kprobes.bpf.o: bpf/kprobes.bpf.c
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF_KPROBE) -c $< -o $@

# frag_kprobes.bpf.c: ip_do_fragment kprobe with CO-RE skb->len read.
# Counts all ip_do_fragment invocations and captures max skb->len for two-signal
# corroboration. Needs __TARGET_ARCH_* for PT_REGS_PARM1.
bpf/frag_kprobes.bpf.o: bpf/frag_kprobes.bpf.c
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF_KPROBE) -c $< -o $@

bpf-check:
	@if [ "$$(uname -s)" = "Darwin" ]; then \
	    echo "ERROR: BPF compilation requires Linux. This host is macOS."; \
	    echo "       Run 'make bpf' inside a Linux container or VM."; \
	    echo "       See docs/linux-dev-environment.md for options."; \
	    exit 1; \
	fi
	@command -v $(CLANG) >/dev/null 2>&1 || \
	    { echo "ERROR: clang not found.  apt install clang"; exit 1; }
	@test -f /usr/include/bpf/bpf_helpers.h || \
	    { echo "ERROR: libbpf headers missing.  apt install libbpf-dev"; exit 1; }
	@test -f /usr/include/linux/bpf.h || \
	    { echo "ERROR: linux UAPI headers missing.  apt install linux-libc-dev"; exit 1; }
	@echo "  prereqs OK  clang=$$(clang --version 2>/dev/null | head -1)  arch=$(_HOST_ARCH)"

# --- TC BPF attach (Linux only, requires lab-up first) ---
attach-bpf: bpf
	@echo "Attaching TC BPF programs..."
	ip netns exec ns1 tc qdisc add dev veth1  clsact 2>/dev/null || true
	ip netns exec ns1 tc filter add dev veth1 ingress bpf da \
	    obj bpf/tc_ingress_eth0.bpf.o sec tc
	ip netns exec ns1 tc qdisc add dev vxlan0 clsact 2>/dev/null || true
	ip netns exec ns1 tc filter add dev vxlan0 egress bpf da \
	    obj bpf/tc_egress_vxlan0.bpf.o sec tc
	@echo "Verify: ip netns exec ns1 tc filter show dev veth1 ingress"

# --- Lab management ---
lab-up:
	sudo bash scripts/setup-netns.sh

lab-down:
	sudo bash scripts/teardown-netns.sh

smoke-small:
	bash scripts/smoke-small-traffic.sh

smoke-large:
	bash scripts/smoke-large-traffic.sh

# Run all four diagnostic scenarios in Docker (requires Docker + privileged mode).
# Builds BPF objects inside the container; uses the pre-compiled Go binary at
# BINARY (default: dist/vxlan-tracer-linux-arm64). See docs/reproducibility.md.
scenarios:
	@if [ -z "$(BINARY)" ]; then \
	    echo "ERROR: set BINARY=/path/to/vxlan-tracer-linux-arm64"; exit 1; fi
	docker run --rm --privileged \
	    -v "$(CURDIR)":/work \
	    -v "$(BINARY)":"$(BINARY)" \
	    ubuntu:22.04 bash -c " \
	        export DEBIAN_FRONTEND=noninteractive; \
	        apt-get update -qq; \
	        apt-get install -y -qq clang llvm libbpf-dev linux-libc-dev \
	            iproute2 iputils-ping iptables python3 python3-scapy > /dev/null 2>&1; \
	        cd /work; \
	        mkdir -p /tmp/bpfobjs; \
	        clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
	            -Wall -Wno-unused-value -Wno-pointer-sign \
	            -c bpf/tc_ingress_eth0.bpf.c -o /tmp/bpfobjs/tc_ingress_eth0.bpf.o; \
	        clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
	            -Wall -Wno-unused-value -Wno-pointer-sign \
	            -c bpf/tc_egress_vxlan0.bpf.c -o /tmp/bpfobjs/tc_egress_vxlan0.bpf.o; \
	        clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
	            -D__TARGET_ARCH_arm64 -Wall -Wno-unused-value -Wno-pointer-sign \
	            -c bpf/kprobes.bpf.c -o /tmp/bpfobjs/kprobes.bpf.o; \
	        clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
	            -D__TARGET_ARCH_arm64 -Wall -Wno-unused-value -Wno-pointer-sign \
	            -c bpf/frag_kprobes.bpf.c -o /tmp/bpfobjs/frag_kprobes.bpf.o; \
	        bash scripts/setup-bpf-fs.sh; \
	        chmod +x '$(BINARY)'; \
	        BINARY='$(BINARY)' BPF_DIR=/tmp/bpfobjs DURATION=15s \
	            bash scripts/run-scenarios.sh; \
	    "

cleanup-bpf:
	sudo bash scripts/cleanup-bpf.sh

# --- Kernel symbol check (Linux only) ---
check-symbols:
	@echo "Checking required kernel symbols..."
	@grep -E " T ip_do_fragment$$| T icmp_rcv$$" /proc/kallsyms \
	    || echo "WARNING: /proc/kallsyms not available or symbols not found"
	@echo "icmp_send (tracepoint-only on kernel 6.10+):"
	@grep -E "__traceiter_icmp_send" /proc/kallsyms | head -2 || echo "  not found"

clean:
	rm -rf dist/ bpf/*.o

help:
	@echo "Targets:"
	@echo "  build                    Go binary (native platform, output: dist/vxlan-tracer)"
	@echo "  build-linux-arm64        Cross-compile for Linux/aarch64"
	@echo "  build-linux-amd64        Cross-compile for Linux/x86_64"
	@echo "  package                  Build both Linux targets + release bundle in dist/release/"
	@echo "  install [PREFIX=...]     Install binary to PREFIX/bin (Linux only, default /usr/local)"
	@echo "  uninstall [PREFIX=...]   Remove installed binary"
	@echo "  test                     go test ./..."
	@echo "  preflight                Check all runtime requirements (Linux + root)"
	@echo "  vet                      go vet"
	@echo "  bpf                      Compile BPF objects (Linux only)"
	@echo "  bpf-check     Check BPF build prerequisites"
	@echo "  attach-bpf    Attach BPF to lab interfaces (Linux, lab must be up)"
	@echo "  lab-up        Create netns + VXLAN lab topology"
	@echo "  lab-down      Tear down lab"
	@echo "  smoke-small   Small traffic test"
	@echo "  smoke-large   Large traffic test"
	@echo "  scenarios     Run 4 end-to-end diagnostic scenarios in Docker (set BINARY=)"
	@echo "  cleanup-bpf   Remove TC filters and pinned maps (idempotent)"
	@echo "  check-symbols Verify kernel symbols in /proc/kallsyms"
	@echo "  clean         Remove build artifacts"
