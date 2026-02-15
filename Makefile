.PHONY: all x86_64 aarch64 run run-x86_64 run-aarch64 disk disk-x86_64 disk-aarch64 clean help
.PHONY: release release-x86_64 release-aarch64 run-release

all: x86_64 aarch64

x86_64:
	zig build x86_64

aarch64:
	zig build aarch64

# Release builds: ReleaseSafe everywhere (keeps bounds/overflow checks)
release: release-x86_64 release-aarch64

release-x86_64:
	zig build x86_64 -Doptimize=ReleaseSafe

release-aarch64:
	zig build aarch64 -Doptimize=ReleaseSafe

run: run-x86_64

run-x86_64: x86_64
	./scripts/run-x86_64.sh

run-release: release-x86_64
	./scripts/run-x86_64.sh

run-aarch64: aarch64
	./scripts/run-aarch64.sh

disk: disk-x86_64

disk-x86_64: x86_64
	./scripts/make-disk-image.sh x86_64

disk-aarch64: aarch64
	./scripts/make-disk-image.sh aarch64

clean:
	rm -rf zig-out .zig-cache *.img

help:
	@echo "Fornax build targets:"
	@echo "  make                Build both architectures (debug kernel, ReleaseSafe userspace)"
	@echo "  make x86_64         Build x86_64"
	@echo "  make aarch64        Build aarch64"
	@echo "  make release        Build both architectures (ReleaseSafe everywhere)"
	@echo "  make run             Run x86_64 in QEMU"
	@echo "  make run-release     Run x86_64 in QEMU (ReleaseSafe kernel)"
	@echo "  make run-aarch64     Run aarch64 in QEMU"
	@echo "  make disk            Create x86_64 bootable disk image"
	@echo "  make clean           Remove build artifacts and disk images"
