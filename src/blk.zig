/// Block device abstraction layer.
///
/// Dispatches readBlock/writeBlock to the first available backend:
/// NVMe > AHCI > virtio-blk (priority order).

const virtio_blk = @import("virtio_blk.zig");
const nvme = @import("nvme.zig");
const ahci = @import("ahci.zig");

pub fn readBlock(block: u64, buf: *[4096]u8) bool {
    if (nvme.isInitialized()) return nvme.readBlock(block, buf);
    if (ahci.isInitialized()) return ahci.readBlock(block, buf);
    if (virtio_blk.isInitialized()) return virtio_blk.readBlock(block, buf);
    return false;
}

pub fn writeBlock(block: u64, buf: *const [4096]u8) bool {
    if (nvme.isInitialized()) return nvme.writeBlock(block, buf);
    if (ahci.isInitialized()) return ahci.writeBlock(block, buf);
    if (virtio_blk.isInitialized()) return virtio_blk.writeBlock(block, buf);
    return false;
}

pub fn isInitialized() bool {
    return nvme.isInitialized() or ahci.isInitialized() or virtio_blk.isInitialized();
}

pub fn getCapacityBlocks() u64 {
    if (nvme.isInitialized()) return nvme.getCapacityBlocks();
    if (ahci.isInitialized()) return ahci.getCapacityBlocks();
    if (virtio_blk.isInitialized()) return virtio_blk.getCapacityBlocks();
    return 0;
}

pub fn getCapacitySectors() u64 {
    if (nvme.isInitialized()) return nvme.getCapacitySectors();
    if (ahci.isInitialized()) return ahci.getCapacitySectors();
    if (virtio_blk.isInitialized()) return virtio_blk.getCapacitySectors();
    return 0;
}
