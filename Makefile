.PHONY: all x86_64 aarch64 riscv64 run run-x86_64 run-smp run-smp-aarch64 run-smp-riscv64 run-aarch64 run-riscv64 disk disk-x86_64 disk-aarch64 clean clean-disk help
.PHONY: release release-x86_64 release-aarch64 release-riscv64 run-release disk-img disk-format
.PHONY: run-posix run-posix-riscv64 run-posix-aarch64
.PHONY: run-containers run-containers-dev run-containers-riscv64 run-containers-aarch64
.PHONY: run-dev test unit-test integration-test
.PHONY: debug debug-smp debug-dev debug-containers
.PHONY: cleanup-network setup-network

all: x86_64 aarch64

x86_64:
	zig build x86_64

aarch64:
	zig build aarch64

riscv64:
	zig build riscv64

# Release builds: ReleaseSafe everywhere (keeps bounds/overflow checks)
release: release-x86_64 release-aarch64

release-x86_64:
	zig build x86_64 -Doptimize=ReleaseSafe

release-aarch64:
	zig build aarch64 -Doptimize=ReleaseSafe

release-riscv64:
	zig build riscv64 -Doptimize=ReleaseSafe

run: run-x86_64

run-x86_64: x86_64
	./scripts/run-x86_64.sh

run-smp: x86_64
	./scripts/run-x86_64.sh -smp 4

run-smp-aarch64: aarch64
	./scripts/run-aarch64.sh -smp 4 -m 4G

run-smp-riscv64: riscv64
	./scripts/run-riscv64.sh -smp 4

run-release: release-x86_64
	./scripts/run-x86_64.sh

run-posix:
	zig build x86_64 -Dposix=true
	./scripts/run-x86_64.sh

run-containers:
	zig build x86_64 -Dcontainers=true
	./scripts/run-x86_64.sh -smp 4 -m 2048

run-containers-dev:
	zig build x86_64 -Dcontainers=true
	./scripts/run-x86_64.sh -smp 8 -m 8192

run-posix-riscv64:
	zig build riscv64 -Dposix=true
	./scripts/run-riscv64.sh

run-posix-aarch64:
	zig build aarch64 -Dposix=true
	./scripts/run-aarch64.sh

run-containers-riscv64:
	zig build riscv64 -Dcontainers=true
	./scripts/run-riscv64.sh

run-containers-aarch64:
	zig build aarch64 -Dcontainers=true
	./scripts/run-aarch64.sh

# Debug targets: QEMU with GDB server (connect with: gdb -x fornax.gdb)
# Auto-generates fornax-syms.gdb from PDB before launching.
debug: x86_64
	./scripts/gen-gdb-syms.sh
	./scripts/run-x86_64.sh --debug

debug-smp: x86_64
	./scripts/gen-gdb-syms.sh
	./scripts/run-x86_64.sh --debug -smp 4

debug-dev: x86_64
	./scripts/gen-gdb-syms.sh
	./scripts/run-x86_64.sh --debug -smp 8 -m 8192

debug-containers:
	zig build x86_64 -Dcontainers=true
	./scripts/gen-gdb-syms.sh
	./scripts/run-x86_64.sh --debug -smp 4 -m 2048

run-dev:
	zig build x86_64
	./scripts/run-x86_64.sh -smp 8 -m 8192

test: unit-test

unit-test:
	zig build test

integration-test:
	python3 -m tests.harness $(INTEGRATION_ARGS)

run-aarch64: aarch64
	./scripts/run-aarch64.sh

run-riscv64: riscv64
	./scripts/run-riscv64.sh

disk: disk-x86_64

disk-x86_64: x86_64
	./scripts/make-disk-image.sh x86_64

disk-aarch64: aarch64
	./scripts/make-disk-image.sh aarch64

disk-img:
	@if [ ! -f fornax-disk.img ]; then \
		echo "Creating blank 8 GB disk image..."; \
		dd if=/dev/zero of=fornax-disk.img bs=1M count=8192 status=none; \
	fi

disk-format: disk-img x86_64
	zig build mkfxfs mkgpt
	./zig-out/bin/mkgpt fornax-disk.img
	$(eval DISK_SIZE := $(shell stat -c%s fornax-disk.img 2>/dev/null || stat -f%z fornax-disk.img))
	./zig-out/bin/mkfxfs fornax-disk.img --offset 1048576 --size $$(( $(DISK_SIZE) - 1048576 - 33 * 512 )) --populate zig-out/rootfs

clean-disk:
	rm -f fornax-disk.img

clean:
	rm -rf zig-out .zig-cache *.img

# Network bridge teardown for TAP-based tests (requires sudo).
# Detaches host NIC from br-fornax, deletes bridge + TAP, restores host networking.
cleanup-network:
	@python3 -c "\
	import subprocess, sys; \
	r = subprocess.run(['ip', '-o', 'link', 'show', 'master', 'br-fornax'], capture_output=True, text=True); \
	nics = [l.split(':')[1].strip().split('@')[0] for l in r.stdout.splitlines() if 'fornax' not in l.split(':')[1]]; \
	[subprocess.run(['sudo', 'ip', 'link', 'set', n, 'nomaster']) for n in nics]; \
	subprocess.run(['sudo', 'ip', 'link', 'del', 'br-fornax'], capture_output=True); \
	subprocess.run(['sudo', 'ip', 'tuntap', 'del', 'dev', 'fornax0', 'mode', 'tap'], capture_output=True); \
	print('Cleaned up br-fornax' + ((' (detached: ' + ', '.join(nics) + ')') if nics else '')); \
	print('Restore host IP: sudo dhclient ' + (nics[0] if nics else '<NIC>') + '  or  nmcli d reapply ' + (nics[0] if nics else '<NIC>')) \
	"

help:
	@echo "Fornax build targets:"
	@echo "  make                Build both architectures (debug kernel, ReleaseSafe userspace)"
	@echo "  make x86_64         Build x86_64"
	@echo "  make aarch64        Build aarch64"
	@echo "  make riscv64        Build riscv64"
	@echo "  make release        Build both architectures (ReleaseSafe everywhere)"
	@echo "  make run             Run x86_64 in QEMU"
	@echo "  make run-smp         Run x86_64 in QEMU with 4 cores"
	@echo "  make run-smp-aarch64 Run aarch64 in QEMU with 4 cores"
	@echo "  make run-smp-riscv64 Run riscv64 in QEMU with 4 cores"
	@echo "  make run-release     Run x86_64 in QEMU (ReleaseSafe kernel)"
	@echo "  make run-aarch64     Run aarch64 in QEMU"
	@echo "  make run-riscv64     Run riscv64 in QEMU"
	@echo "  make run-posix       Run x86_64 with C/POSIX realm support (includes TCC)"
	@echo "  make run-posix-riscv64  Run riscv64 with C/POSIX realm support"
	@echo "  make run-posix-aarch64  Run aarch64 with C/POSIX realm support"
	@echo "  make run-containers  Run x86_64 with container support + TLS (4 cores, 2GB)"
	@echo "  make run-containers-riscv64  Run riscv64 with container support"
	@echo "  make run-containers-aarch64  Run aarch64 with container support"
	@echo "  make run-containers-dev  Run x86_64 with containers (8 cores, 8GB)"
	@echo "  make debug           Run x86_64 with GDB server (connect: gdb -x fornax.gdb)"
	@echo "  make debug-smp       Run x86_64 with GDB server + 4 cores"
	@echo "  make debug-dev       Run x86_64 with GDB server + 8 cores + 8GB RAM"
	@echo "  make debug-containers  Run x86_64 with GDB server + containers"
	@echo "  make run-dev         Run x86_64 with 8 cores and 8GB RAM"
	@echo "  make test            Run unit tests (host-targeted zig test)"
	@echo "  make unit-test       Run unit tests (alias for test)"
	@echo "  make integration-test  Run all integration tests (headless QEMU)"
	@echo "    INTEGRATION_ARGS='--session x86_64'          Run x86_64 tests only"
	@echo "    INTEGRATION_ARGS='--session riscv64'         Run riscv64 tests only"
	@echo "    INTEGRATION_ARGS='--session aarch64'         Run aarch64 tests only"
	@echo "    INTEGRATION_ARGS='--session riscv64 --filter container_pull'  Single test"
	@echo "  make disk            Create x86_64 bootable disk image"
	@echo "  make clean-disk      Remove disk image (re-created and formatted on next run)"
	@echo "  make cleanup-network Tear down TAP bridge (br-fornax) and restore host NIC"
	@echo "  make clean           Remove build artifacts and disk images"
