/// Virtio-input driver for keyboard input.
///
/// Discovers a virtio-input PCI device (vendor 0x1AF4, device 0x1052),
/// initializes via modern virtio transport, and reads EV_KEY events
/// from the event queue (queue 0).

const klog = @import("klog.zig");
const pci = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/pci.zig"),
    .riscv64 => @import("arch/riscv64/pci.zig"),
    else => @compileError("unsupported architecture"),
};
const virtio = @import("virtio.zig");
const virtio_modern = @import("virtio_modern.zig");
const pic = @import("pic.zig");
const keyboard = @import("keyboard.zig");

const interrupts = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("arch/x86_64/interrupts.zig"),
    .riscv64 => @import("arch/riscv64/interrupts.zig"),
    else => @compileError("unsupported architecture"),
};

/// Virtio-input event structure (8 bytes, matches Linux input_event for virtio).
const VirtioInputEvent = extern struct {
    type: u16,
    code: u16,
    value: u32,
};

/// Linux input event types
const EV_KEY: u16 = 0x01;

const EVENT_QUEUE: u16 = 0; // eventq
const NUM_EVENT_BUFFERS: usize = 16;

/// Pre-allocated event buffers (identity-mapped physical addresses).
var event_buffers: [NUM_EVENT_BUFFERS]VirtioInputEvent = undefined;

var device: ?virtio_modern.VirtioModernDevice = null;
var eventq: ?virtio.Virtqueue = null;

/// Initialize the virtio-input driver. Returns true if a device was found.
pub fn init() bool {
    // Find virtio-input device: vendor 0x1AF4, device 0x1052
    const pci_dev = pci.findDevice(0x1AF4, 0x1052) orelse {
        klog.debug("virtio-input: no device found\n");
        return false;
    };

    klog.debug("virtio-input: found device at slot ");
    klog.debugDec(pci_dev.slot);
    klog.debug(" IRQ ");
    klog.debugDec(pci_dev.interrupt_line);
    klog.debug("\n");

    // Initialize via modern transport
    var dev = virtio_modern.initDevice(pci_dev) orelse {
        klog.err("virtio-input: modern init failed\n");
        return false;
    };

    // No special features needed for input
    virtio_modern.finishInit(&dev, 0);

    // Set up event queue (queue 0)
    var vq = virtio_modern.setupQueue(&dev, EVENT_QUEUE) orelse {
        klog.err("virtio-input: failed to setup event queue\n");
        return false;
    };

    // Pre-post event buffers (device-writable, 8 bytes each)
    for (0..NUM_EVENT_BUFFERS) |i| {
        event_buffers[i] = .{ .type = 0, .code = 0, .value = 0 };
        const phys_addr: u64 = @intFromPtr(&event_buffers[i]);
        _ = virtio.addBuffer(&vq, phys_addr, @sizeOf(VirtioInputEvent), true);
    }

    // Notify device that buffers are available
    virtio_modern.notifyQueue(&dev, EVENT_QUEUE);

    device = dev;
    eventq = vq;

    // Register IRQ handler
    const irq = pci_dev.interrupt_line;
    if (!interrupts.registerIrqHandler(irq, handleIrq)) {
        klog.err("virtio-input: failed to register IRQ handler\n");
        return false;
    }

    // Unmask the IRQ
    pic.unmask(irq);

    klog.info("Keyboard ready.\n");
    return true;
}

/// IRQ handler — called from interrupt dispatch. Returns true if we handled it.
fn handleIrq() bool {
    const dev = &(device orelse return false);
    const vq = &(eventq orelse return false);

    // Check ISR status (clears on read)
    const isr = virtio_modern.readIsr(dev);
    if (isr & 1 == 0) return false; // Not our interrupt

    // Process used buffers
    var processed: u32 = 0;
    while (vq.last_used_idx != vq.used.idx) {
        const used_idx = vq.last_used_idx % vq.size;
        const desc_idx = @as(u16, @truncate(vq.used_ring[used_idx].id));

        // Read the event from the buffer
        if (desc_idx < NUM_EVENT_BUFFERS) {
            const event = &event_buffers[desc_idx];

            if (event.type == EV_KEY) {
                // value: 0 = release, 1 = press, 2 = repeat
                keyboard.handleEvdevKey(event.code, event.value);
            }

            // Repost this buffer
            event.* = .{ .type = 0, .code = 0, .value = 0 };
            const phys_addr: u64 = @intFromPtr(event);
            vq.desc[desc_idx] = .{
                .addr = phys_addr,
                .len = @sizeOf(VirtioInputEvent),
                .flags = virtio.VRING_DESC_F_WRITE,
                .next = 0,
            };

            // Add to available ring
            const avail_idx = vq.avail.idx;
            vq.avail_ring[avail_idx % vq.size] = desc_idx;
            virtio.memoryBarrier();
            vq.avail.idx = avail_idx +% 1;
        }

        vq.last_used_idx +%= 1;
        processed += 1;
    }

    if (processed > 0) {
        virtio_modern.notifyQueue(dev, EVENT_QUEUE);
    }

    return true;
}
