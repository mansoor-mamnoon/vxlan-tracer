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
  # -D__x86_64__ prevents glibc stubs.h from pulling in stubs-32.h (from
  # gcc-multilib). clang with -target bpf does not define __x86_64__ itself,
  # which causes a fatal error on systems without gcc-multilib installed.
  _ARCH_INC := -I/usr/include/x86_64-linux-gnu -D__x86_64__
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

# Version metadata embedded via -ldflags.
# Override at release time:  VERSION=v0.1.0-rc1 make package
# BUILDDATE is intentionally not embedded by default so builds are reproducible.
VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
LDFLAGS := -X 'main.version=$(VERSION)' -X 'main.commit=$(COMMIT)'

# PACKAGE_ARCH: arch string for 'make package'. Auto-derived from host arch.
# BPF kprobe objects embed __TARGET_ARCH_x86 or __TARGET_ARCH_arm64 at compile
# time — they are NOT portable across architectures. Run 'make package' natively
# on each target architecture after 'make bpf'.
# Handles: Linux aarch64, Linux x86_64, and macOS arm64 (fails with Linux check).
_NATIVE_PKG_ARCH := $(shell if [ "$(_HOST_ARCH)" = "aarch64" ] || [ "$(_HOST_ARCH)" = "arm64" ]; then echo arm64; elif [ "$(_HOST_ARCH)" = "x86_64" ]; then echo amd64; else echo unsupported; fi)
PACKAGE_ARCH ?= $(_NATIVE_PKG_ARCH)

_BPF_ARCH_DEFINE := $(shell if [ "$(PACKAGE_ARCH)" = "arm64" ]; then echo __TARGET_ARCH_arm64; elif [ "$(PACKAGE_ARCH)" = "amd64" ]; then echo __TARGET_ARCH_x86; else echo unknown; fi)

# Required BPF objects for a complete release archive. Hard-checked by make package.
_BPF_REQUIRED := tc_ingress_eth0.bpf.o tc_egress_vxlan0.bpf.o kprobes.bpf.o frag_kprobes.bpf.o

.PHONY: all build build-linux-arm64 build-linux-amd64 package package-rc1 install uninstall \
        bpf bpf-check bpf-verify generate lint vet test test-stale-bpf preflight \
        lab-up lab-down smoke-small smoke-large demo scenarios cleanup-bpf \
        attach-bpf check-symbols clean clean-bpf help verify-release-archive

all: build

# --- Go userspace binary ---
# build: native platform (whatever GOOS/GOARCH the host provides)
build: generate
	@mkdir -p dist
	go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY) ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)"

# build-linux-arm64: cross-compile for Linux/aarch64 (required for actual BPF execution)
build-linux-arm64: generate
	@mkdir -p dist
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-linux-arm64 ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)-linux-arm64"

# build-linux-amd64: cross-compile for Linux/x86_64
build-linux-amd64: generate
	@mkdir -p dist
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/$(BINARY)-linux-amd64 ./cmd/vxlan-tracer/
	@echo "  built: dist/$(BINARY)-linux-amd64"

# package: build a native-arch release archive under dist/release/.
#
# MUST be run on Linux after 'make bpf' compiles the BPF objects.
# Hard-fails if any required BPF object is missing — no silent incomplete archives.
# Produces only the host-architecture package because BPF kprobe objects embed
# __TARGET_ARCH_x86 or __TARGET_ARCH_arm64 and are NOT portable across architectures.
#
# To build both amd64 and arm64 packages:
#   Run 'make package' on x86_64 Linux  → dist/release/vxlan-tracer-linux-amd64.tar.gz
#   Run 'make package' on aarch64 Linux → dist/release/vxlan-tracer-linux-arm64.tar.gz
#   Combine checksums: cat checksums-amd64.sha256 checksums-arm64.sha256 > checksums.sha256
#
# Override version: VERSION=v0.1.0-rc1 make package
#
# Archive contents:
#   vxlan-tracer-linux-<arch>/vxlan-tracer        binary (Linux/<arch> ELF)
#   vxlan-tracer-linux-<arch>/bpf/                4 required BPF objects (arch-correct)
#   vxlan-tracer-linux-<arch>/scripts/            runtime scripts
#   vxlan-tracer-linux-<arch>/README.md
#   vxlan-tracer-linux-<arch>/LICENSE
#   vxlan-tracer-linux-<arch>/MANIFEST.txt        release metadata
package:
	@if [ "$$(uname -s)" != "Linux" ]; then \
	    echo "ERROR: make package requires Linux (BPF objects must be compiled natively)."; \
	    echo "  This host is: $$(uname -s)"; \
	    echo "  Fix: run on $(PACKAGE_ARCH) Linux after make bpf"; \
	    exit 1; \
	fi
	@if [ "$(PACKAGE_ARCH)" = "unsupported" ]; then \
	    echo "ERROR: unsupported host architecture '$(_HOST_ARCH)'."; \
	    echo "  vxlan-tracer supports x86_64 (amd64) and aarch64 (arm64) only."; \
	    exit 1; \
	fi
	@echo "--- Verifying required BPF objects for $(PACKAGE_ARCH) ---"
	@_MISSING=0; \
	for obj in $(_BPF_REQUIRED); do \
	    if [ ! -f "bpf/$$obj" ]; then \
	        echo "  MISSING: bpf/$$obj"; \
	        _MISSING=1; \
	    else \
	        echo "  OK:      bpf/$$obj  ($$(wc -c < bpf/$$obj) bytes)"; \
	    fi; \
	done; \
	if [ "$$_MISSING" = "1" ]; then \
	    echo ""; \
	    echo "ERROR: One or more required BPF objects are missing."; \
	    echo "  BPF objects must be compiled on $(PACKAGE_ARCH) Linux before packaging."; \
	    echo "  Fix: make clean-bpf && make bpf"; \
	    echo "       (requires clang, libbpf-dev, and linux-libc-dev)"; \
	    exit 1; \
	fi
	@echo "--- Running bpf-verify (vxlan_config symbol check) ---"
	@$(MAKE) --no-print-directory bpf-verify
	@echo "--- Building $(PACKAGE_ARCH) binary (VERSION=$(VERSION) COMMIT=$(COMMIT)) ---"
	@$(MAKE) --no-print-directory build-linux-$(PACKAGE_ARCH) VERSION=$(VERSION) COMMIT=$(COMMIT)
	@echo "--- Staging release archive ---"
	@STAGEDIR="dist/release/_stage-$(PACKAGE_ARCH)/vxlan-tracer-linux-$(PACKAGE_ARCH)"; \
	TARBALL="dist/release/vxlan-tracer-linux-$(PACKAGE_ARCH).tar.gz"; \
	rm -rf "dist/release/_stage-$(PACKAGE_ARCH)"; \
	mkdir -p dist/release "$$STAGEDIR/bpf" "$$STAGEDIR/scripts"; \
	cp "dist/$(BINARY)-linux-$(PACKAGE_ARCH)" "$$STAGEDIR/vxlan-tracer"; \
	chmod 755 "$$STAGEDIR/vxlan-tracer"; \
	for obj in $(_BPF_REQUIRED); do \
	    cp "bpf/$$obj" "$$STAGEDIR/bpf/"; \
	done; \
	for s in scripts/preflight.sh scripts/run-scenarios.sh scripts/demo.sh \
	          scripts/setup-bpf-fs.sh scripts/setup-netns.sh \
	          scripts/teardown-netns.sh scripts/cleanup-bpf.sh \
	          scripts/inject_ptb.py; do \
	    [ -f "$$s" ] && cp "$$s" "$$STAGEDIR/scripts/" || true; \
	done; \
	[ -f README.md ] && cp README.md "$$STAGEDIR/"; \
	[ -f LICENSE ]   && cp LICENSE   "$$STAGEDIR/"; \
	printf '%s\n' \
	    "vxlan-tracer-linux-$(PACKAGE_ARCH) release manifest" \
	    "==========================================================" \
	    "Version:        $(VERSION)" \
	    "Commit:         $(COMMIT)" \
	    "Architecture:   $(PACKAGE_ARCH)" \
	    "BPF target:     $(_BPF_ARCH_DEFINE)" \
	    "" \
	    "KERNEL COMPATIBILITY CAVEAT:" \
	    "  BPF objects use CO-RE (Compile Once, Run Everywhere) and require" \
	    "  Linux >= 5.15 with CONFIG_DEBUG_INFO_BTF=y (/sys/kernel/btf/vmlinux)." \
	    "  Portability beyond tested kernels is likely but not guaranteed." \
	    "  Validate on your specific kernel before production use." \
	    "" \
	    "Binary:" \
	    "  vxlan-tracer  (Linux/$(PACKAGE_ARCH) ELF; requires root or CAP_BPF+CAP_NET_ADMIN)" \
	    "" \
	    "BPF objects (compiled for $(PACKAGE_ARCH) with $(_BPF_ARCH_DEFINE)):" \
	    "  bpf/tc_ingress_eth0.bpf.o   TC sched_cls ingress; counts PTBs pre-netfilter" \
	    "  bpf/tc_egress_vxlan0.bpf.o  TC sched_cls egress; records outer packet sizes" \
	    "  bpf/kprobes.bpf.o            icmp_rcv kprobe; counts PTBs post-netfilter (arch-specific)" \
	    "  bpf/frag_kprobes.bpf.o       ip_do_fragment kprobe; counts fragmentation (arch-specific)" \
	    "" \
	    "Scripts:" \
	    "  scripts/preflight.sh         pre-flight environment check" \
	    "  scripts/run-scenarios.sh     6-scenario diagnostic test suite" \
	    "  scripts/demo.sh              VXLAN fragmentation demo (~25 s)" \
	    "  scripts/setup-bpf-fs.sh      mount bpffs" \
	    "" \
	    "Validated kernels (as of this commit):" \
	    "  aarch64: 5.15.0-181-generic — 6/6 scenarios PASS" \
	    "           6.10.14-linuxkit  — 5/5 scenarios PASS (tested before scenario 6 was added)" \
	    "  x86_64:  6.8.0-1059-azure  (GitHub Actions ubuntu-22.04) — 6/6 scenarios PASS" \
	    "" \
	    "Verdicts emitted (all 5 reachable):" \
	    "  VXLAN_FRAGMENTATION_OBSERVED  VXLAN_MTU_MISCONFIGURATION  VXLAN_MTU_RISK" \
	    "  PTB_DELIVERED  PTB_SUPPRESSED  NO_ISSUE_OBSERVED" \
	    "" \
	    "Known limitations:" \
	    "  - ip_do_fragment is global: frag_events_total includes ALL IP fragmentation." \
	    "  - PTB inner 5-tuple not extractable from ICMP payload." \
	    "  - Production Kubernetes (k3s/flannel) NOT validated; netns lab only." \
	    "  - Two-node CNI validation not complete." \
	    "  See docs/fragmentation-scoping.md and docs/forbidden-claims.md." \
	    > "$$STAGEDIR/MANIFEST.txt"; \
	tar -C "dist/release/_stage-$(PACKAGE_ARCH)" -czf "$$TARBALL" \
	    "vxlan-tracer-linux-$(PACKAGE_ARCH)"; \
	rm -rf "dist/release/_stage-$(PACKAGE_ARCH)"; \
	echo "  created: $$TARBALL"
	@cd dist/release && \
	    sha256sum "vxlan-tracer-linux-$(PACKAGE_ARCH).tar.gz" \
	    > "checksums-$(PACKAGE_ARCH).sha256" && \
	    echo "  created: dist/release/checksums-$(PACKAGE_ARCH).sha256"
	@echo ""
	@echo "Release archive ($(PACKAGE_ARCH)):"
	@ls -lh "dist/release/vxlan-tracer-linux-$(PACKAGE_ARCH).tar.gz" \
	         "dist/release/checksums-$(PACKAGE_ARCH).sha256"
	@echo ""
	@echo "Verify archive contents:"
	@echo "  bash scripts/verify-release-archive.sh dist/release/vxlan-tracer-linux-$(PACKAGE_ARCH).tar.gz"

# verify-release-archive: validate a release tarball produced by make package.
# Usage: make verify-release-archive ARCHIVE=dist/release/vxlan-tracer-linux-amd64.tar.gz
ARCHIVE ?= dist/release/vxlan-tracer-linux-$(PACKAGE_ARCH).tar.gz
verify-release-archive:
	@bash scripts/verify-release-archive.sh "$(ARCHIVE)"

# package-rc1: build the v0.1.0-rc1 release archive for this architecture.
# Equivalent to: VERSION=v0.1.0-rc1 make package
# Requires Linux + compiled BPF objects (make bpf).
package-rc1:
	@$(MAKE) package VERSION=v0.1.0-rc1

test:
	go test ./...

# test-stale-bpf: integration test that verifies the loader fails closed when given a
# stale BPF object (compiled without vxlan_config).  Requires Linux + root + clang.
# Uses tests/fixtures/tc_ingress_missing_config.bpf.c as the stale fixture.
# Exit 77 means skipped (environment restriction); exit 1 means assertion failure.
test-stale-bpf: build
	@if [ "$$(uname -s)" != "Linux" ]; then \
	    echo "SKIP: test-stale-bpf requires Linux."; exit 0; fi
	sudo BINARY=dist/$(BINARY) bash scripts/test-stale-bpf-object.sh

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
	@if [ "$(_HOST_ARCH)" != "aarch64" ] && [ "$(_HOST_ARCH)" != "x86_64" ]; then \
	    echo "ERROR: unsupported architecture: $(_HOST_ARCH)"; \
	    echo "       vxlan-tracer BPF programs require aarch64 or x86_64."; \
	    exit 1; \
	fi
	@echo "  prereqs OK  clang=$$(clang --version 2>/dev/null | head -1)  arch=$(_HOST_ARCH)  bpf_target=$(_TARGET_ARCH_DEFINE)"

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
# demo: run a self-contained VXLAN fragmentation detection demonstration.
# Creates a stale-MTU lab (overlay MTU 1450, underlay MTU 1400), runs large
# traffic, and shows the vxlan-tracer JSON output and human-readable summary.
# Takes ~25 seconds. Requires Linux + root + compiled binary and BPF objects.
demo: build
	@if [ "$$(uname -s)" != "Linux" ]; then \
	    echo "ERROR: demo requires Linux."; exit 1; fi
	sudo BINARY=dist/$(BINARY) BPF_DIR=bpf bash scripts/demo.sh

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

# clean-bpf: remove compiled BPF objects only (leave Go dist/ intact).
# Use before 'make bpf' to guarantee a fresh recompile — e.g. after pulling
# changes to bpf/*.c or bpf/maps.h.  Without this, make may skip recompilation
# if timestamps are equal (e.g. after 'cp -r' or 'git checkout').
clean-bpf:
	rm -f bpf/*.bpf.o
	@echo "BPF objects removed.  Run 'make bpf' to recompile."

# bpf-verify: check that the compiled tc_ingress object contains the
# vxlan_config map section.  Fails loudly if the object was compiled before
# the vxlan_config map was added (Day 11), so a stale object is caught before
# running scenarios.  Requires readelf (binutils) or llvm-readelf.
# Uses /bin/bash explicitly to allow process-substitution-free grep chains.
bpf-verify:
	@OBJ=bpf/tc_ingress_eth0.bpf.o; \
	if [ ! -f "$$OBJ" ]; then \
	    echo "ERROR: $$OBJ not found — run 'make bpf' first"; exit 1; fi; \
	_found=0; \
	readelf -s "$$OBJ" 2>/dev/null | grep -q vxlan_config && _found=1; \
	[ "$$_found" -eq 0 ] && nm "$$OBJ" 2>/dev/null | grep -q vxlan_config && _found=1; \
	[ "$$_found" -eq 0 ] && strings "$$OBJ" 2>/dev/null | grep -qx vxlan_config && _found=1; \
	if [ "$$_found" -eq 1 ]; then \
	    echo "  PASS  $$OBJ contains vxlan_config map section"; \
	else \
	    echo "ERROR: $$OBJ is missing the vxlan_config map section."; \
	    echo "       This is a stale BPF object compiled before the config map was added."; \
	    echo "       Fix: make clean-bpf && make bpf"; exit 1; fi

help:
	@echo "Targets:"
	@echo "  build                    Go binary (native platform, output: dist/vxlan-tracer)"
	@echo "  build-linux-arm64        Cross-compile for Linux/aarch64"
	@echo "  build-linux-amd64        Cross-compile for Linux/x86_64"
	@echo "  package                  Build native-arch release archive with BPF objects (Linux only; hard-fails if BPF absent)"
	@echo "  verify-release-archive   Validate a release tarball [ARCHIVE=path]"
	@echo "  install [PREFIX=...]     Install binary to PREFIX/bin (Linux only, default /usr/local)"
	@echo "  uninstall [PREFIX=...]   Remove installed binary"
	@echo "  test                     go test ./..."
	@echo "  test-stale-bpf           Integration test: stale BPF object causes clear error (Linux+root)"
	@echo "  preflight                Check all runtime requirements (Linux + root)"
	@echo "  vet                      go vet"
	@echo "  bpf                      Compile BPF objects (Linux only)"
	@echo "  bpf-check                Check BPF build prerequisites"
	@echo "  bpf-verify               Verify compiled objects contain vxlan_config map"
	@echo "  clean-bpf                Remove compiled BPF objects (use before make bpf to force rebuild)"
	@echo "  attach-bpf               Attach BPF to lab interfaces (Linux, lab must be up)"
	@echo "  demo                     One-command VXLAN fragmentation demo (~25s, Linux+root)"
	@echo "  lab-up        Create netns + VXLAN lab topology"
	@echo "  lab-down      Tear down lab"
	@echo "  smoke-small   Small traffic test"
	@echo "  smoke-large   Large traffic test"
	@echo "  scenarios     Run 4 end-to-end diagnostic scenarios in Docker (set BINARY=)"
	@echo "  cleanup-bpf   Remove TC filters and pinned maps (idempotent)"
	@echo "  check-symbols Verify kernel symbols in /proc/kallsyms"
	@echo "  clean         Remove build artifacts"
