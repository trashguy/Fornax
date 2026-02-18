.PHONY: all x86_64 aarch64 riscv64 run run-x86_64 run-smp run-aarch64 run-riscv64 disk disk-x86_64 disk-aarch64 clean clean-disk help
.PHONY: release release-x86_64 release-aarch64 release-riscv64 run-release disk-img disk-format

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

run-release: release-x86_64
	./scripts/run-x86_64.sh

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
		echo "Creating blank 64 MB disk image..."; \
		dd if=/dev/zero of=fornax-disk.img bs=1M count=64 status=none; \
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

help:
	@echo "Fornax build targets:"
	@echo "  make                Build both architectures (debug kernel, ReleaseSafe userspace)"
	@echo "  make x86_64         Build x86_64"
	@echo "  make aarch64        Build aarch64"
	@echo "  make riscv64        Build riscv64"
	@echo "  make release        Build both architectures (ReleaseSafe everywhere)"
	@echo "  make run             Run x86_64 in QEMU"
	@echo "  make run-smp         Run x86_64 in QEMU with 4 cores"
	@echo "  make run-release     Run x86_64 in QEMU (ReleaseSafe kernel)"
	@echo "  make run-aarch64     Run aarch64 in QEMU"
	@echo "  make run-riscv64     Run riscv64 in QEMU"
	@echo "  make disk            Create x86_64 bootable disk image"
	@echo "  make clean-disk      Remove disk image (re-created and formatted on next run)"
	@echo "  make clean           Remove build artifacts and disk images"
