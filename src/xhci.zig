// xHCI USB 3.0 Host Controller Driver
//
// Follows the virtio driver pattern: file-level globals, synchronous polling,
// pmm.allocPage() for DMA buffers. All xHCI data structures (DCBAA, rings,
// device contexts) fit in single 4KB pages.

const pmm = @import("pmm.zig");
const klog = @import("klog.zig");
const paging = @import("arch/x86_64/paging.zig");
const keyboard = @import("keyboard.zig");
const process = @import("process.zig");
const mem = @import("mem.zig");

// ── TRB (Transfer Request Block) ────────────────────────────────────

const Trb = packed struct {
    parameter: u64,
    status: u32,
    control: u32,
};

// TRB types
const TRB_NORMAL = 1;
const TRB_SETUP_STAGE = 2;
const TRB_DATA_STAGE = 3;
const TRB_STATUS_STAGE = 4;
const TRB_LINK = 6;
const TRB_ENABLE_SLOT = 9;
const TRB_ADDRESS_DEVICE = 11;
const TRB_CONFIGURE_ENDPOINT = 12;
const TRB_EVALUATE_CONTEXT = 13;
const TRB_NO_OP_CMD = 23;
const TRB_TRANSFER_EVENT = 32;
const TRB_CMD_COMPLETION = 33;
const TRB_PORT_STATUS_CHANGE = 34;

// TRB completion codes
const TRB_COMP_SUCCESS = 1;
const TRB_COMP_SHORT_PACKET = 13;

// ── xHCI Register Offsets ───────────────────────────────────────────

// Capability registers (offset from mmio_base)
const CAPLENGTH = 0x00; // u8
const HCIVERSION = 0x02; // u16
const HCSPARAMS1 = 0x04; // u32
const HCSPARAMS2 = 0x08; // u32
const HCCPARAMS1 = 0x10; // u32
const DBOFF = 0x14; // u32
const RTSOFF = 0x18; // u32

// Operational registers (offset from op_base)
const USBCMD = 0x00;
const USBSTS = 0x04;
const PAGESIZE = 0x08;
const DNCTRL = 0x14;
const CRCR = 0x18; // u64
const DCBAAP = 0x30; // u64
const CONFIG = 0x38;

// USBCMD bits
const USBCMD_RS = 1 << 0; // Run/Stop
const USBCMD_HCRST = 1 << 1; // Host Controller Reset
const USBCMD_INTE = 1 << 2; // Interrupter Enable

// USBSTS bits
const USBSTS_HCH = 1 << 0; // HC Halted
const USBSTS_CNR = 1 << 11; // Controller Not Ready

// Port status register bits
const PORTSC_CCS = 1 << 0; // Current Connect Status
const PORTSC_PED = 1 << 1; // Port Enabled/Disabled
const PORTSC_PR = 1 << 4; // Port Reset
const PORTSC_PLS_MASK: u32 = 0xF << 5; // Port Link State
const PORTSC_PP = 1 << 9; // Port Power
const PORTSC_SPEED_MASK: u32 = 0xF << 10; // Port Speed
const PORTSC_PRC = 1 << 21; // Port Reset Change
const PORTSC_CSC = 1 << 17; // Connect Status Change
const PORTSC_WRC = 1 << 19; // Warm Port Reset Change
const PORTSC_PEC = 1 << 18; // Port Enabled/Disabled Change
const PORTSC_PLC = 1 << 22; // Port Link State Change
const PORTSC_CEC = 1 << 23; // Config Error Change
const PORTSC_CHANGE_BITS = PORTSC_CSC | PORTSC_PEC | PORTSC_WRC | PORTSC_PRC | PORTSC_PLC | PORTSC_CEC;
// Bits that must be preserved (not write-1-to-clear) when writing PORTSC
const PORTSC_PRESERVE = PORTSC_PP | PORTSC_PED;

// Interrupter register offsets (from runtime_base + 0x20)
const IMAN = 0x00;
const IMOD = 0x04;
const ERSTSZ = 0x08;
const ERSTBA = 0x10; // u64
const ERDP = 0x18; // u64

// ── Speeds ──────────────────────────────────────────────────────────

const USB_SPEED_FULL = 1;
const USB_SPEED_LOW = 2;
const USB_SPEED_HIGH = 3;
const USB_SPEED_SUPER = 4;

// ── USB Descriptor Types ────────────────────────────────────────────

const USB_DESC_DEVICE = 1;
const USB_DESC_CONFIGURATION = 2;
const USB_DESC_STRING = 3;
const USB_DESC_INTERFACE = 4;
const USB_DESC_ENDPOINT = 5;
const USB_DESC_HID = 0x21;

// USB request types
const USB_DIR_IN = 0x80;
const USB_DIR_OUT = 0x00;
const USB_REQ_GET_DESCRIPTOR = 6;
const USB_REQ_SET_CONFIGURATION = 9;
const USB_REQ_SET_PROTOCOL = 0x0B;
const USB_REQ_SET_IDLE = 0x0A;

// HID class
const USB_CLASS_HID = 3;
const HID_PROTOCOL_KEYBOARD = 1;
const HID_PROTOCOL_MOUSE = 2;

// ── Event Ring Segment Table Entry ──────────────────────────────────

const ErstEntry = packed struct {
    ring_segment_base: u64,
    ring_segment_size: u16,
    reserved1: u16 = 0,
    reserved2: u32 = 0,
};

// ── USB Device ──────────────────────────────────────────────────────

const HidType = enum { none, kbd, mouse };

const UsbDevice = struct {
    slot_id: u8 = 0,
    port: u8 = 0,
    speed: u8 = 0,
    state: enum { empty, slot_enabled, addressed, configured } = .empty,
    vendor_id: u16 = 0,
    product_id: u16 = 0,
    class_code: u8 = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,
    num_configs: u8 = 0,
    hid_type: HidType = .none,
    // String descriptor indices
    manufacturer_idx: u8 = 0,
    product_idx: u8 = 0,
    // Cached strings
    manufacturer_str: [64]u8 = [_]u8{0} ** 64,
    product_str: [64]u8 = [_]u8{0} ** 64,
    manufacturer_len: u8 = 0,
    product_len: u8 = 0,
    // Device context pages (physical addresses)
    input_ctx_phys: u64 = 0,
    output_ctx_phys: u64 = 0,
    ep0_ring_phys: u64 = 0,
    ep0_enqueue: u8 = 0,
    ep0_cycle: u1 = 1,
    // HID interrupt endpoint
    hid_ep_ring_phys: u64 = 0,
    hid_ep_enqueue: u8 = 0,
    hid_ep_cycle: u1 = 1,
    hid_ep_dci: u8 = 0,
    hid_buf_phys: u64 = 0,
    hid_interval: u8 = 0,
    hid_max_packet: u16 = 0,
    // Keyboard state (previous report for press/release detection)
    prev_kbd_report: [8]u8 = [_]u8{0} ** 8,
};

const MAX_USB_DEVICES = 8;
var usb_devices: [MAX_USB_DEVICES]UsbDevice = [_]UsbDevice{.{}} ** MAX_USB_DEVICES;
var usb_device_count: u8 = 0;

// ── Mouse Ring Buffer ───────────────────────────────────────────────

pub const MouseEvent = struct {
    buttons: u8,
    dx: i8,
    dy: i8,
};

const MOUSE_RING_SIZE = 64;
var mouse_ring: [MOUSE_RING_SIZE]MouseEvent = undefined;
var mouse_ring_write: u8 = 0;
var mouse_ring_read: u8 = 0;
var mouse_waiter: ?*@import("process.zig").Process = null;

pub fn mouseDataAvailable() bool {
    return mouse_ring_read != mouse_ring_write;
}

pub fn mouseRead(buf: [*]u8, len: usize) usize {
    var written: usize = 0;
    while (written + 3 <= len and mouse_ring_read != mouse_ring_write) {
        const ev = mouse_ring[mouse_ring_read % MOUSE_RING_SIZE];
        buf[written] = ev.buttons;
        buf[written + 1] = @bitCast(ev.dx);
        buf[written + 2] = @bitCast(ev.dy);
        written += 3;
        mouse_ring_read +%= 1;
    }
    return written;
}

pub fn setMouseWaiter(proc: ?*@import("process.zig").Process) void {
    mouse_waiter = proc;
}

fn pushMouseEvent(ev: MouseEvent) void {
    mouse_ring[mouse_ring_write % MOUSE_RING_SIZE] = ev;
    mouse_ring_write +%= 1;
    if (mouse_waiter) |w| {
        process.markReady(w);
        mouse_waiter = null;
    }
}

// ── Controller State ────────────────────────────────────────────────

var mmio_base: u64 = 0;
var cap_length: u8 = 0;
var op_base: u64 = 0;
var runtime_base: u64 = 0;
var doorbell_base: u64 = 0;
var max_slots: u8 = 0;
var max_ports: u8 = 0;
var context_size: u8 = 32; // 32 or 64 bytes

// DCBAA
var dcbaa_phys: u64 = 0;

// Command ring
var cmd_ring_phys: u64 = 0;
var cmd_enqueue: u8 = 0;
var cmd_cycle: u1 = 1;

// Event ring
var evt_ring_phys: u64 = 0;
var erst_phys: u64 = 0;
var evt_dequeue: u16 = 0;
var evt_cycle: u1 = 1;

// DMA scratch page for control transfers
var scratch_phys: u64 = 0;

var initialized = false;

pub fn isInitialized() bool {
    return initialized;
}

// ── MMIO Helpers ────────────────────────────────────────────────────

fn mmioRead32(addr: u64) u32 {
    const virt: usize = @intFromPtr(paging.physPtr(addr));
    var result: u32 = undefined;
    asm volatile ("movl (%[addr]), %[result]"
        : [result] "=r" (result),
        : [addr] "r" (virt),
        : .{.memory = true});
    return result;
}

fn mmioWrite32(addr: u64, val: u32) void {
    const virt: usize = @intFromPtr(paging.physPtr(addr));
    asm volatile ("movl %[val], (%[addr])"
        :
        : [val] "r" (val), [addr] "r" (virt),
        : .{.memory = true});
}

fn mmioRead64(addr: u64) u64 {
    // Read as two 32-bit halves for portability
    const lo: u64 = mmioRead32(addr);
    const hi: u64 = mmioRead32(addr + 4);
    return lo | (hi << 32);
}

fn mmioWrite64(addr: u64, val: u64) void {
    mmioWrite32(addr, @truncate(val));
    mmioWrite32(addr + 4, @truncate(val >> 32));
}

fn readCap(offset: u32) u32 {
    return mmioRead32(mmio_base + offset);
}

fn readOp(offset: u32) u32 {
    return mmioRead32(op_base + offset);
}

fn writeOp(offset: u32, val: u32) void {
    mmioWrite32(op_base + offset, val);
}

fn readOpU64(offset: u32) u64 {
    return mmioRead64(op_base + offset);
}

fn writeOpU64(offset: u32, val: u64) void {
    mmioWrite64(op_base + offset, val);
}

fn readRt(interrupter: u32, offset: u32) u32 {
    return mmioRead32(runtime_base + 0x20 + interrupter * 0x20 + offset);
}

fn writeRt(interrupter: u32, offset: u32, val: u32) void {
    mmioWrite32(runtime_base + 0x20 + interrupter * 0x20 + offset, val);
}

fn writeRtU64(interrupter: u32, offset: u32, val: u64) void {
    mmioWrite64(runtime_base + 0x20 + interrupter * 0x20 + offset, val);
}

fn readRtU64(interrupter: u32, offset: u32) u64 {
    return mmioRead64(runtime_base + 0x20 + interrupter * 0x20 + offset);
}

fn writeDb(slot: u8, val: u32) void {
    mmioWrite32(doorbell_base + @as(u32, slot) * 4, val);
}

fn readPortsc(port: u8) u32 {
    return mmioRead32(op_base + 0x400 + @as(u32, port - 1) * 0x10);
}

fn writePortsc(port: u8, val: u32) void {
    mmioWrite32(op_base + 0x400 + @as(u32, port - 1) * 0x10, val);
}

fn portSpeed(portsc: u32) u8 {
    return @truncate((portsc & PORTSC_SPEED_MASK) >> 10);
}

fn speedName(speed: u8) []const u8 {
    return switch (speed) {
        USB_SPEED_FULL => "Full",
        USB_SPEED_LOW => "Low",
        USB_SPEED_HIGH => "High",
        USB_SPEED_SUPER => "Super",
        else => "Unknown",
    };
}

// ── Phase 400: Init & PCI Detection ─────────────────────────────────

pub fn init() bool {
    if (@import("builtin").cpu.arch != .x86_64) return false;

    const pci = @import("arch/x86_64/pci.zig");

    // Find xHCI controller (class 0x0C, subclass 0x03, prog_if 0x30)
    const dev = pci.findXhci() orelse {
        klog.debug("xhci: no controller found\n");
        return false;
    };

    klog.info("xhci: found at PCI slot ");
    klog.infoDec(dev.slot);

    // Enable bus mastering + memory space
    pci.enableBusMastering(dev);

    // Read BAR0 (MMIO)
    mmio_base = dev.memBase(0) orelse {
        klog.err("xhci: BAR0 not memory-mapped\n");
        return false;
    };

    // If BAR is above 4 GB, map the MMIO region into kernel page tables.
    if (mmio_base >= 0x1_0000_0000) {
        if (!mapMmioRegion(mmio_base, 0x10000)) {
            klog.err("xhci: failed to map MMIO region\n");
            return false;
        }
    }

    // Read capability registers
    // Offset 0x00: [7:0] CAPLENGTH, [31:16] HCIVERSION
    const cap_reg0 = readCap(0x00);
    cap_length = @truncate(cap_reg0 & 0xFF);
    const version = (cap_reg0 >> 16) & 0xFFFF;
    const hcsparams1 = readCap(HCSPARAMS1);
    const hccparams1 = readCap(HCCPARAMS1);

    max_slots = @truncate(hcsparams1 & 0xFF);
    max_ports = @truncate((hcsparams1 >> 24) & 0xFF);

    // Context size: bit 2 of HCCPARAMS1
    context_size = if (hccparams1 & (1 << 2) != 0) 64 else 32;

    op_base = mmio_base + cap_length;
    runtime_base = mmio_base + (readCap(RTSOFF) & 0xFFFFFFE0);
    doorbell_base = mmio_base + (readCap(DBOFF) & 0xFFFFFFFC);

    klog.info(", v");
    klog.infoDec(version >> 8);
    klog.info(".");
    klog.infoDec(version & 0xFF);
    klog.info(", slots=");
    klog.infoDec(max_slots);
    klog.info(", ports=");
    klog.infoDec(max_ports);
    klog.info("\n");

    // Phase 401: Reset and start
    if (!haltController()) return false;
    if (!resetController()) return false;
    if (!setupDcbaa()) return false;
    if (!setupCommandRing()) return false;
    if (!setupEventRing()) return false;

    // Allocate scratch page for control transfer data
    scratch_phys = pmm.allocPage() orelse {
        klog.err("xhci: scratch page alloc failed\n");
        return false;
    };
    zeroPage(scratch_phys);

    if (!startController()) return false;

    // Phase 402: Scan ports and enable devices
    scanPorts();

    initialized = true;
    return true;
}

// ── Phase 401: Controller Reset & Ring Setup ────────────────────────

fn haltController() bool {
    var cmd = readOp(USBCMD);
    cmd &= ~@as(u32, USBCMD_RS);
    writeOp(USBCMD, cmd);

    // Poll for HCH (Halted) — up to 16ms
    var timeout: u32 = 16000;
    while (timeout > 0) : (timeout -= 1) {
        if (readOp(USBSTS) & USBSTS_HCH != 0) {
            klog.debug("xhci: halted\n");
            return true;
        }
        microDelay();
    }
    klog.err("xhci: halt timeout\n");
    return false;
}

fn resetController() bool {
    writeOp(USBCMD, USBCMD_HCRST);

    // Poll for HCRST clear
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (readOp(USBCMD) & USBCMD_HCRST == 0) break;
        microDelay();
    }
    if (timeout == 0) {
        klog.err("xhci: reset timeout\n");
        return false;
    }

    // Wait for CNR (Controller Not Ready) to clear
    timeout = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (readOp(USBSTS) & USBSTS_CNR == 0) break;
        microDelay();
    }
    if (timeout == 0) {
        klog.err("xhci: CNR timeout\n");
        return false;
    }

    klog.debug("xhci: reset OK\n");
    return true;
}

fn setupDcbaa() bool {
    dcbaa_phys = pmm.allocPage() orelse {
        klog.err("xhci: DCBAA alloc failed\n");
        return false;
    };
    zeroPage(dcbaa_phys);

    // Set max device slots
    writeOp(CONFIG, @as(u32, max_slots));

    // Write DCBAAP
    writeOpU64(DCBAAP, dcbaa_phys);

    klog.debug("xhci: DCBAA at ");
    klog.debugHex(dcbaa_phys);
    klog.debug("\n");
    return true;
}

fn setupCommandRing() bool {
    cmd_ring_phys = pmm.allocPage() orelse {
        klog.err("xhci: cmd ring alloc failed\n");
        return false;
    };
    zeroPage(cmd_ring_phys);
    cmd_enqueue = 0;
    cmd_cycle = 1;

    // Set up Link TRB at entry 63 (last before 4K boundary)
    // 256 TRBs per page, but use 63 for link at end of usable portion
    const link_offset = @as(u64, 63) * 16;
    const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(cmd_ring_phys + link_offset)));
    link_ptr.* = .{
        .parameter = cmd_ring_phys, // link back to start
        .status = 0,
        .control = (@as(u32, TRB_LINK) << 10) | (1 << 1) | @as(u32, cmd_cycle), // Toggle Cycle + type + cycle
    };

    // Write CRCR — ring base with cycle bit
    writeOpU64(CRCR, cmd_ring_phys | cmd_cycle);

    klog.debug("xhci: cmd ring at ");
    klog.debugHex(cmd_ring_phys);
    klog.debug("\n");
    return true;
}

fn setupEventRing() bool {
    // Allocate event ring segment (256 TRBs)
    evt_ring_phys = pmm.allocPage() orelse {
        klog.err("xhci: event ring alloc failed\n");
        return false;
    };
    zeroPage(evt_ring_phys);

    // Allocate ERST (Event Ring Segment Table) — one entry
    erst_phys = pmm.allocPage() orelse {
        klog.err("xhci: ERST alloc failed\n");
        return false;
    };
    zeroPage(erst_phys);

    // Fill ERST entry 0
    const erst_entry: *ErstEntry = @ptrCast(@alignCast(paging.physPtr(erst_phys)));
    erst_entry.* = .{
        .ring_segment_base = evt_ring_phys,
        .ring_segment_size = 256,
    };

    evt_dequeue = 0;
    evt_cycle = 1;

    // Program interrupter 0
    writeRt(0, ERSTSZ, 1); // one segment
    // Set ERDP first (before ERSTBA to avoid race)
    writeRtU64(0, ERDP, evt_ring_phys);
    // Set ERSTBA (writing this enables the event ring)
    writeRtU64(0, ERSTBA, erst_phys);

    klog.debug("xhci: event ring at ");
    klog.debugHex(evt_ring_phys);
    klog.debug("\n");
    return true;
}

fn startController() bool {
    var cmd = readOp(USBCMD);
    cmd |= USBCMD_RS | USBCMD_INTE;
    writeOp(USBCMD, cmd);

    // Poll for HCH clear (running)
    var timeout: u32 = 16000;
    while (timeout > 0) : (timeout -= 1) {
        if (readOp(USBSTS) & USBSTS_HCH == 0) {
            klog.debug("xhci: started\n");
            return true;
        }
        microDelay();
    }
    klog.err("xhci: start timeout\n");
    return false;
}

// ── Phase 402: Port Scanning & Slot Enable ──────────────────────────

fn scanPorts() void {
    for (1..@as(u16, max_ports) + 1) |port_u16| {
        const port: u8 = @truncate(port_u16);
        const portsc = readPortsc(port);
        if (portsc & PORTSC_CCS != 0) {
            const speed = portSpeed(portsc);
            klog.info("xhci: port ");
            klog.infoDec(port);
            klog.info(" connected (");
            klog.info(speedName(speed));
            klog.info(")\n");

            if (resetPort(port)) {
                if (enableSlotAndAddress(port, speed)) |_| {} else {
                    klog.err("xhci: failed to enable device on port ");
                    klog.errDec(port);
                    klog.err("\n");
                }
            }
        }
    }
}

fn resetPort(port: u8) bool {
    // Read-modify-write: preserve PP, clear change bits, set PR
    var portsc = readPortsc(port);
    portsc = (portsc & PORTSC_PRESERVE & ~@as(u32, PORTSC_CHANGE_BITS)) | PORTSC_PR;
    writePortsc(port, portsc);

    // Poll for PRC (Port Reset Change)
    var timeout: u32 = 500000;
    while (timeout > 0) : (timeout -= 1) {
        portsc = readPortsc(port);
        if (portsc & PORTSC_PRC != 0) {
            // Clear PRC by writing 1
            writePortsc(port, (portsc & PORTSC_PRESERVE & ~@as(u32, PORTSC_CHANGE_BITS)) | PORTSC_PRC);
            if (portsc & PORTSC_PED != 0) {
                klog.debug("xhci: port ");
                klog.debugDec(port);
                klog.debug(" reset OK\n");
                return true;
            }
            klog.err("xhci: port not enabled after reset\n");
            return false;
        }
        microDelay();
    }
    klog.err("xhci: port reset timeout\n");
    return false;
}

fn enqueueCommand(trb: Trb) void {
    const offset = @as(u64, cmd_enqueue) * 16;
    const ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(cmd_ring_phys + offset)));

    // Set cycle bit in control
    var ctrl = trb.control;
    ctrl = (ctrl & ~@as(u32, 1)) | @as(u32, cmd_cycle);
    ptr.* = .{
        .parameter = trb.parameter,
        .status = trb.status,
        .control = ctrl,
    };

    cmd_enqueue += 1;
    if (cmd_enqueue >= 63) {
        // We hit the Link TRB — toggle cycle and wrap
        // The Link TRB's cycle bit needs to match current cmd_cycle for it to be consumed
        const link_offset = @as(u64, 63) * 16;
        const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(cmd_ring_phys + link_offset)));
        var link_ctrl = link_ptr.control;
        link_ctrl = (link_ctrl & ~@as(u32, 1)) | @as(u32, cmd_cycle);
        link_ptr.control = link_ctrl;
        cmd_cycle ^= 1;
        cmd_enqueue = 0;
    }
}

fn ringCommandDoorbell() void {
    writeDb(0, 0);
}

fn pollEvent(timeout_us: u32) ?Trb {
    var remaining = timeout_us;
    while (remaining > 0) : (remaining -= 1) {
        const offset = @as(u64, evt_dequeue) * 16;
        const ptr: *volatile Trb = @ptrCast(@alignCast(paging.physPtr(evt_ring_phys + offset)));
        const trb = ptr.*;

        // Check cycle bit matches expected
        if ((trb.control & 1) == @as(u32, evt_cycle)) {
            evt_dequeue += 1;
            if (evt_dequeue >= 256) {
                evt_dequeue = 0;
                evt_cycle ^= 1;
            }
            // Update ERDP to acknowledge
            const new_erdp = evt_ring_phys + @as(u64, evt_dequeue) * 16;
            writeRtU64(0, ERDP, new_erdp | (1 << 3)); // EHB bit
            return trb;
        }
        microDelay();
    }
    return null;
}

/// Poll for a Command Completion event, skipping Port Status Change events.
fn pollCommandEvent(timeout_us: u32) ?Trb {
    var remaining = timeout_us;
    while (remaining > 0) {
        const evt = pollEvent(1) orelse {
            remaining -= 1;
            continue;
        };
        const trb_type: u8 = @truncate((evt.control >> 10) & 0x3F);
        if (trb_type == TRB_CMD_COMPLETION) return evt;
        // Skip PSC and other non-command events
        remaining -= 1;
    }
    return null;
}

/// Poll for a Transfer Event, skipping Port Status Change events.
fn pollTransferEvent(timeout_us: u32) ?Trb {
    var remaining = timeout_us;
    while (remaining > 0) {
        const evt = pollEvent(1) orelse {
            remaining -= 1;
            continue;
        };
        const trb_type: u8 = @truncate((evt.control >> 10) & 0x3F);
        if (trb_type == TRB_TRANSFER_EVENT) return evt;
        // Skip PSC and other non-transfer events
        remaining -= 1;
    }
    return null;
}

fn enableSlot() ?u8 {
    enqueueCommand(.{
        .parameter = 0,
        .status = 0,
        .control = @as(u32, TRB_ENABLE_SLOT) << 10,
    });
    ringCommandDoorbell();

    const evt = pollCommandEvent(500000) orelse {
        klog.err("xhci: enable slot timeout\n");
        return null;
    };

    const cc: u8 = @truncate((evt.status >> 24) & 0xFF);
    if (cc != TRB_COMP_SUCCESS) {
        klog.err("xhci: enable slot failed, cc=");
        klog.errDec(cc);
        klog.err("\n");
        return null;
    }

    const slot_id: u8 = @truncate((evt.control >> 24) & 0xFF);
    klog.debug("xhci: slot ");
    klog.debugDec(slot_id);
    klog.debug(" enabled\n");
    return slot_id;
}

// ── Phase 403: Address Device & Descriptors ─────────────────────────

fn enableSlotAndAddress(port: u8, speed: u8) ?*UsbDevice {
    if (usb_device_count >= MAX_USB_DEVICES) return null;

    const slot_id = enableSlot() orelse return null;

    const idx = usb_device_count;
    usb_device_count += 1;
    var dev = &usb_devices[idx];
    dev.* = .{
        .slot_id = slot_id,
        .port = port,
        .speed = speed,
        .state = .slot_enabled,
    };

    if (!setupDeviceContext(dev)) return null;
    if (!addressDevice(dev)) return null;

    // Read device descriptor
    getDeviceDescriptor(dev);

    // Read string descriptors
    if (dev.manufacturer_idx != 0) {
        dev.manufacturer_len = getStringDescriptor(dev, dev.manufacturer_idx, &dev.manufacturer_str);
    }
    if (dev.product_idx != 0) {
        dev.product_len = getStringDescriptor(dev, dev.product_idx, &dev.product_str);
    }

    klog.info("xhci: device ");
    klog.infoDec(slot_id);
    klog.info(" VID=");
    klog.infoHex(dev.vendor_id);
    klog.info(" PID=");
    klog.infoHex(dev.product_id);
    if (dev.product_len > 0) {
        klog.info(" \"");
        klog.info(dev.product_str[0..dev.product_len]);
        klog.info("\"");
    }
    klog.info("\n");

    // Phase 405: Configure HID devices
    configureHidDevice(dev);

    return dev;
}

fn setupDeviceContext(dev: *UsbDevice) bool {
    // Allocate Input Context page
    dev.input_ctx_phys = pmm.allocPage() orelse return false;
    zeroPage(dev.input_ctx_phys);

    // Allocate Output Context page
    dev.output_ctx_phys = pmm.allocPage() orelse return false;
    zeroPage(dev.output_ctx_phys);

    // Allocate EP0 Transfer Ring
    dev.ep0_ring_phys = pmm.allocPage() orelse return false;
    zeroPage(dev.ep0_ring_phys);
    dev.ep0_enqueue = 0;
    dev.ep0_cycle = 1;

    // Set up EP0 Link TRB at entry 63
    const link_offset = @as(u64, 63) * 16;
    const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.ep0_ring_phys + link_offset)));
    link_ptr.* = .{
        .parameter = dev.ep0_ring_phys,
        .status = 0,
        .control = (@as(u32, TRB_LINK) << 10) | (1 << 1) | 1, // Toggle + type + cycle=1
    };

    // Set DCBAA[slot_id] to output context
    const dcbaa_entry_ptr: *u64 = @ptrCast(@alignCast(paging.physPtr(dcbaa_phys + @as(u64, dev.slot_id) * 8)));
    dcbaa_entry_ptr.* = dev.output_ctx_phys;

    return true;
}

fn addressDevice(dev: *UsbDevice) bool {
    const ctx_sz: u64 = context_size;

    // Fill Input Context
    // Input Control Context at offset 0 (first context_size bytes)
    // Add flags: bit 0 (slot) + bit 1 (EP0)
    const icc_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(dev.input_ctx_phys + ctx_sz + 0)));
    icc_ptr.* = 0x3; // A0 (Slot) + A1 (EP0) — at offset context_size (drop=0, add=3)

    // Hmm, add flags are at offset 0x04, drop flags at 0x00 within the Input Control Context
    // Actually the Input Control Context is: drop_flags(u32), add_flags(u32), ...
    // It starts at offset 0 of the Input Context (before the slot/EP contexts)
    // Wait — re-read the spec more carefully:
    // The Input Context starts with Input Control Context, then Device Context fields
    // Input Control Context: offset 0 = Drop, offset 4 = Add
    const drop_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(dev.input_ctx_phys)));
    drop_ptr.* = 0;
    const add_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(dev.input_ctx_phys + 4)));
    add_ptr.* = 0x3; // Add Slot (bit 0) + EP0 (bit 1)

    // Slot Context at offset context_size (one context_size past ICC)
    const slot_ctx_base = dev.input_ctx_phys + ctx_sz;
    const slot_dw0_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(slot_ctx_base)));
    // DW0: Route String (0) | Speed | Context Entries (1 = EP0 only)
    slot_dw0_ptr.* = (@as(u32, dev.speed) << 20) | (1 << 27); // context_entries=1

    const slot_dw1_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(slot_ctx_base + 4)));
    // DW1: Root Hub Port Number
    slot_dw1_ptr.* = @as(u32, dev.port) << 16;

    // Endpoint 0 Context at offset 2*context_size (EP0 is DCI 1, but stored after slot ctx)
    const ep0_ctx_base = dev.input_ctx_phys + 2 * ctx_sz;

    // DW1: EP Type (4 = Control Bi-directional) | MaxPacketSize | CErr=3
    const max_packet: u16 = switch (dev.speed) {
        USB_SPEED_SUPER => 512,
        USB_SPEED_HIGH => 64,
        USB_SPEED_FULL => 64,
        USB_SPEED_LOW => 8,
        else => 64,
    };
    const ep0_dw1_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(ep0_ctx_base + 4)));
    ep0_dw1_ptr.* = (3 << 1) | (4 << 3) | (@as(u32, max_packet) << 16); // CErr=3, EPType=Control, MaxPacket

    // DW2-3: TR Dequeue Pointer (physical addr of EP0 ring | DCS=1)
    const ep0_dq_ptr: *u64 = @ptrCast(@alignCast(paging.physPtr(ep0_ctx_base + 8)));
    ep0_dq_ptr.* = dev.ep0_ring_phys | 1; // DCS = 1

    // DW4: Average TRB Length (8 for control)
    const ep0_dw4_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(ep0_ctx_base + 16)));
    ep0_dw4_ptr.* = 8;

    // Issue Address Device command
    enqueueCommand(.{
        .parameter = dev.input_ctx_phys,
        .status = 0,
        .control = (@as(u32, TRB_ADDRESS_DEVICE) << 10) | (@as(u32, dev.slot_id) << 24),
    });
    ringCommandDoorbell();

    const evt = pollCommandEvent(1000000) orelse {
        klog.err("xhci: address device timeout\n");
        return false;
    };

    const cc: u8 = @truncate((evt.status >> 24) & 0xFF);
    if (cc != TRB_COMP_SUCCESS) {
        klog.err("xhci: address device failed, cc=");
        klog.errDec(cc);
        klog.err("\n");
        return false;
    }

    dev.state = .addressed;
    klog.debug("xhci: device ");
    klog.debugDec(dev.slot_id);
    klog.debug(" addressed\n");
    return true;
}

fn controlTransfer(dev: *UsbDevice, setup: [8]u8, data_phys: u64, data_len: u16, dir_in: bool) ?u16 {
    // Setup Stage TRB
    const setup_param = @as(u64, setup[0]) |
        (@as(u64, setup[1]) << 8) |
        (@as(u64, setup[2]) << 16) |
        (@as(u64, setup[3]) << 24) |
        (@as(u64, setup[4]) << 32) |
        (@as(u64, setup[5]) << 40) |
        (@as(u64, setup[6]) << 48) |
        (@as(u64, setup[7]) << 56);

    const trt: u32 = if (data_len > 0) (if (dir_in) @as(u32, 3) else @as(u32, 2)) else 0; // TRT: 3=IN, 2=OUT, 0=No Data

    enqueueEp0(dev, .{
        .parameter = setup_param,
        .status = 8, // TRB Transfer Length = 8 (setup packet size)
        .control = (@as(u32, TRB_SETUP_STAGE) << 10) | (1 << 6) | (trt << 16), // IDT=1 (Immediate Data Transfer)
    });

    // Data Stage TRB (if data)
    if (data_len > 0) {
        const dir_bit: u32 = if (dir_in) (1 << 16) else 0;
        enqueueEp0(dev, .{
            .parameter = data_phys,
            .status = @as(u32, data_len),
            .control = (@as(u32, TRB_DATA_STAGE) << 10) | dir_bit,
        });
    }

    // Status Stage TRB
    const status_dir: u32 = if (data_len > 0 and dir_in) 0 else (1 << 16); // opposite direction of data
    enqueueEp0(dev, .{
        .parameter = 0,
        .status = 0,
        .control = (@as(u32, TRB_STATUS_STAGE) << 10) | status_dir | (1 << 5), // IOC=1
    });

    // Ring doorbell for this slot, EP0 (DCI=1)
    writeDb(dev.slot_id, 1);

    // Poll for transfer event (skipping PSC events)
    const evt = pollTransferEvent(1000000) orelse {
        klog.err("xhci: control transfer timeout\n");
        return null;
    };

    const cc: u8 = @truncate((evt.status >> 24) & 0xFF);
    if (cc != TRB_COMP_SUCCESS and cc != TRB_COMP_SHORT_PACKET) {
        klog.err("xhci: control transfer cc=");
        klog.errDec(cc);
        klog.err("\n");
        return null;
    }

    const residual: u16 = @truncate(evt.status & 0xFFFFFF);
    return if (data_len > residual) data_len - residual else 0;
}

fn enqueueEp0(dev: *UsbDevice, trb: Trb) void {
    const offset = @as(u64, dev.ep0_enqueue) * 16;
    const ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.ep0_ring_phys + offset)));

    var ctrl = trb.control;
    ctrl = (ctrl & ~@as(u32, 1)) | @as(u32, dev.ep0_cycle);
    ptr.* = .{
        .parameter = trb.parameter,
        .status = trb.status,
        .control = ctrl,
    };

    dev.ep0_enqueue += 1;
    if (dev.ep0_enqueue >= 63) {
        const link_offset = @as(u64, 63) * 16;
        const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.ep0_ring_phys + link_offset)));
        var link_ctrl = link_ptr.control;
        link_ctrl = (link_ctrl & ~@as(u32, 1)) | @as(u32, dev.ep0_cycle);
        link_ptr.control = link_ctrl;
        dev.ep0_cycle ^= 1;
        dev.ep0_enqueue = 0;
    }
}

fn getDeviceDescriptor(dev: *UsbDevice) void {
    // GET_DESCRIPTOR(DEVICE), 18 bytes
    const setup = [8]u8{
        USB_DIR_IN, USB_REQ_GET_DESCRIPTOR,
        0x00, USB_DESC_DEVICE, // wValue: descriptor type (high) + index (low)
        0x00, 0x00, // wIndex
        18, 0x00, // wLength
    };

    const transferred = controlTransfer(dev, setup, scratch_phys, 18, true) orelse return;
    if (transferred < 8) return;

    // Parse 18-byte device descriptor
    const buf = paging.physPtr(scratch_phys);
    dev.class_code = buf[4];
    dev.subclass = buf[5];
    dev.protocol = buf[6];
    // max_packet_size_ep0 = buf[7] — we already configured this
    dev.vendor_id = @as(u16, buf[8]) | (@as(u16, buf[9]) << 8);
    dev.product_id = @as(u16, buf[10]) | (@as(u16, buf[11]) << 8);
    dev.manufacturer_idx = buf[14];
    dev.product_idx = buf[15];
    dev.num_configs = buf[17];
}

fn getStringDescriptor(dev: *UsbDevice, index: u8, out: *[64]u8) u8 {
    const setup = [8]u8{
        USB_DIR_IN, USB_REQ_GET_DESCRIPTOR,
        index, USB_DESC_STRING,
        0x09, 0x04, // wIndex: English (US)
        64, 0x00, // wLength
    };

    const transferred = controlTransfer(dev, setup, scratch_phys, 64, true) orelse return 0;
    if (transferred < 2) return 0;

    const buf = paging.physPtr(scratch_phys);
    const desc_len = buf[0];
    if (desc_len < 2 or buf[1] != USB_DESC_STRING) return 0;

    // Decode UTF-16LE to ASCII
    var out_len: u8 = 0;
    var i: u8 = 2;
    while (i + 1 < desc_len and out_len < 63) : (i += 2) {
        const ch = buf[i]; // low byte of UTF-16LE
        if (buf[i + 1] == 0 and ch >= 0x20 and ch < 0x7F) {
            out[out_len] = ch;
            out_len += 1;
        } else {
            out[out_len] = '?';
            out_len += 1;
        }
    }
    return out_len;
}

// ── Phase 405: HID Configuration ────────────────────────────────────

fn configureHidDevice(dev: *UsbDevice) void {
    // Read configuration descriptor to find HID interfaces
    const cfg_setup = [8]u8{
        USB_DIR_IN, USB_REQ_GET_DESCRIPTOR,
        0x00, USB_DESC_CONFIGURATION,
        0x00, 0x00,
        0xFF, 0x00, // request up to 255 bytes
    };

    const cfg_transferred = controlTransfer(dev, cfg_setup, scratch_phys, 255, true) orelse return;
    if (cfg_transferred < 4) return;

    const buf = paging.physPtr(scratch_phys);
    const total_len: u16 = @as(u16, buf[2]) | (@as(u16, buf[3]) << 8);
    const parse_len = if (total_len < cfg_transferred) total_len else cfg_transferred;

    // Parse descriptors looking for HID interface + Interrupt IN endpoint
    var hid_iface: ?u8 = null;
    var hid_proto: u8 = 0;
    var ep_addr: u8 = 0;
    var ep_interval: u8 = 0;
    var ep_max_packet: u16 = 0;

    var pos: u16 = 0;
    while (pos + 2 <= parse_len) {
        const dlen = buf[pos];
        const dtype = buf[pos + 1];
        if (dlen < 2) break;

        if (dtype == USB_DESC_INTERFACE and pos + 9 <= parse_len) {
            if (buf[pos + 5] == USB_CLASS_HID) {
                hid_iface = buf[pos + 2]; // interface number
                hid_proto = buf[pos + 7]; // protocol
            }
        } else if (dtype == USB_DESC_ENDPOINT and pos + 7 <= parse_len and hid_iface != null) {
            const ep = buf[pos + 2];
            if (ep & 0x80 != 0) { // IN endpoint
                ep_addr = ep;
                ep_interval = buf[pos + 6];
                ep_max_packet = @as(u16, buf[pos + 4]) | (@as(u16, buf[pos + 5] & 0x07) << 8);
            }
        }

        pos += dlen;
    }

    if (hid_iface == null or ep_addr == 0) return;

    // Determine HID type
    dev.hid_type = switch (hid_proto) {
        HID_PROTOCOL_KEYBOARD => .kbd,
        HID_PROTOCOL_MOUSE => .mouse,
        else => .none,
    };

    if (dev.hid_type == .none) return;

    klog.info("xhci: HID ");
    klog.info(if (dev.hid_type == .kbd) "keyboard" else "mouse");
    klog.info(" on port ");
    klog.infoDec(dev.port);
    klog.info("\n");

    // SET_CONFIGURATION(1)
    _ = controlTransfer(dev, [8]u8{
        USB_DIR_OUT, USB_REQ_SET_CONFIGURATION,
        0x01, 0x00,
        0x00, 0x00,
        0x00, 0x00,
    }, 0, 0, false);

    // SET_PROTOCOL(0) — boot protocol
    _ = controlTransfer(dev, [8]u8{
        0x21, USB_REQ_SET_PROTOCOL, // class, interface
        0x00, 0x00, // boot protocol
        hid_iface.?, 0x00,
        0x00, 0x00,
    }, 0, 0, false);

    // SET_IDLE(0) — no idle rate
    _ = controlTransfer(dev, [8]u8{
        0x21, USB_REQ_SET_IDLE,
        0x00, 0x00,
        hid_iface.?, 0x00,
        0x00, 0x00,
    }, 0, 0, false);

    // Set up interrupt endpoint
    if (!setupInterruptEndpoint(dev, ep_addr, ep_interval, ep_max_packet)) return;

    dev.state = .configured;

    // Pre-post transfer TRBs for HID reports
    postHidTransfers(dev);
}

fn setupInterruptEndpoint(dev: *UsbDevice, ep_addr: u8, interval: u8, max_packet: u16) bool {
    const ep_num = ep_addr & 0x0F;
    const dci = ep_num * 2 + 1; // IN endpoint DCI = ep_num * 2 + 1
    dev.hid_ep_dci = dci;
    dev.hid_interval = interval;
    dev.hid_max_packet = max_packet;

    // Allocate HID transfer ring
    dev.hid_ep_ring_phys = pmm.allocPage() orelse return false;
    zeroPage(dev.hid_ep_ring_phys);
    dev.hid_ep_enqueue = 0;
    dev.hid_ep_cycle = 1;

    // Link TRB at 63
    const link_offset = @as(u64, 63) * 16;
    const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.hid_ep_ring_phys + link_offset)));
    link_ptr.* = .{
        .parameter = dev.hid_ep_ring_phys,
        .status = 0,
        .control = (@as(u32, TRB_LINK) << 10) | (1 << 1) | 1,
    };

    // Allocate DMA buffer page for HID reports
    dev.hid_buf_phys = pmm.allocPage() orelse return false;
    zeroPage(dev.hid_buf_phys);

    // Issue Configure Endpoint command
    // Reuse input context — update it with new endpoint info
    zeroPage(dev.input_ctx_phys);
    const ctx_sz: u64 = context_size;

    // Input Control Context: Add slot (bit 0) + this endpoint (bit dci)
    const add_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(dev.input_ctx_phys + 4)));
    add_ptr.* = 1 | (@as(u32, 1) << @as(u5, @truncate(dci)));

    // Update Slot Context — set context entries to max of current and dci
    const slot_ctx_base = dev.input_ctx_phys + ctx_sz;
    const slot_dw0_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(slot_ctx_base)));
    slot_dw0_ptr.* = (@as(u32, dev.speed) << 20) | (@as(u32, dci) << 27);

    const slot_dw1_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(slot_ctx_base + 4)));
    slot_dw1_ptr.* = @as(u32, dev.port) << 16;

    // Endpoint Context at offset (1 + dci) * context_size
    const ep_ctx_base = dev.input_ctx_phys + (@as(u64, 1 + dci) * ctx_sz);

    // DW1: CErr=3, EP Type (7 = Interrupt IN), Max Packet Size
    const ep_dw1_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(ep_ctx_base + 4)));
    ep_dw1_ptr.* = (3 << 1) | (7 << 3) | (@as(u32, max_packet) << 16);

    // DW0: Interval — for HS/SS, xHCI interval = interval-1 (already in log2 form)
    const ep_dw0_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(ep_ctx_base)));
    const xhci_interval: u8 = if (interval > 0) interval - 1 else 0;
    ep_dw0_ptr.* = @as(u32, xhci_interval) << 16;

    // DW2-3: TR Dequeue Pointer
    const ep_dq_ptr: *u64 = @ptrCast(@alignCast(paging.physPtr(ep_ctx_base + 8)));
    ep_dq_ptr.* = dev.hid_ep_ring_phys | 1;

    // DW4: Average TRB Length = max_packet, Max ESIT Payload = max_packet
    const ep_dw4_ptr: *u32 = @ptrCast(@alignCast(paging.physPtr(ep_ctx_base + 16)));
    ep_dw4_ptr.* = @as(u32, max_packet) | (@as(u32, max_packet) << 16);

    // Issue Configure Endpoint
    enqueueCommand(.{
        .parameter = dev.input_ctx_phys,
        .status = 0,
        .control = (@as(u32, TRB_CONFIGURE_ENDPOINT) << 10) | (@as(u32, dev.slot_id) << 24),
    });
    ringCommandDoorbell();

    const evt = pollCommandEvent(1000000) orelse {
        klog.err("xhci: configure endpoint timeout\n");
        return false;
    };

    const cc: u8 = @truncate((evt.status >> 24) & 0xFF);
    if (cc != TRB_COMP_SUCCESS) {
        klog.err("xhci: configure endpoint cc=");
        klog.errDec(cc);
        klog.err("\n");
        return false;
    }

    klog.debug("xhci: interrupt EP configured, DCI=");
    klog.debugDec(dci);
    klog.debug("\n");
    return true;
}

fn postHidTransfers(dev: *UsbDevice) void {
    // Post multiple Normal TRBs to keep the endpoint fed
    const report_size: u16 = if (dev.hid_type == .kbd) 8 else 4;
    const num_posts: u8 = 8; // pre-post 8 transfers

    var i: u8 = 0;
    while (i < num_posts) : (i += 1) {
        const buf_offset = @as(u64, i) * 64; // space out in DMA buffer
        enqueueHidEp(dev, .{
            .parameter = dev.hid_buf_phys + buf_offset,
            .status = @as(u32, report_size),
            .control = (@as(u32, TRB_NORMAL) << 10) | (1 << 5), // IOC=1
        });
    }

    // Ring doorbell for this slot + endpoint DCI
    writeDb(dev.slot_id, @as(u32, dev.hid_ep_dci));
}

fn enqueueHidEp(dev: *UsbDevice, trb: Trb) void {
    const offset = @as(u64, dev.hid_ep_enqueue) * 16;
    const ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.hid_ep_ring_phys + offset)));

    var ctrl = trb.control;
    ctrl = (ctrl & ~@as(u32, 1)) | @as(u32, dev.hid_ep_cycle);
    ptr.* = .{
        .parameter = trb.parameter,
        .status = trb.status,
        .control = ctrl,
    };

    dev.hid_ep_enqueue += 1;
    if (dev.hid_ep_enqueue >= 63) {
        const link_offset = @as(u64, 63) * 16;
        const link_ptr: *Trb = @ptrCast(@alignCast(paging.physPtr(dev.hid_ep_ring_phys + link_offset)));
        var link_ctrl = link_ptr.control;
        link_ctrl = (link_ctrl & ~@as(u32, 1)) | @as(u32, dev.hid_ep_cycle);
        link_ptr.control = link_ctrl;
        dev.hid_ep_cycle ^= 1;
        dev.hid_ep_enqueue = 0;
    }
}

// ── HID Event Processing ────────────────────────────────────────────

pub fn pollUsbHid() void {
    if (!initialized) return;

    // Check event ring for transfer events (non-blocking)
    while (true) {
        const offset = @as(u64, evt_dequeue) * 16;
        const ptr: *volatile Trb = @ptrCast(@alignCast(paging.physPtr(evt_ring_phys + offset)));
        const trb = ptr.*;

        if ((trb.control & 1) != @as(u32, evt_cycle)) break;

        evt_dequeue += 1;
        if (evt_dequeue >= 256) {
            evt_dequeue = 0;
            evt_cycle ^= 1;
        }

        const trb_type: u8 = @truncate((trb.control >> 10) & 0x3F);
        if (trb_type == TRB_TRANSFER_EVENT) {
            handleTransferEvent(trb);
        }

        // Update ERDP
        const new_erdp = evt_ring_phys + @as(u64, evt_dequeue) * 16;
        writeRtU64(0, ERDP, new_erdp | (1 << 3));
    }
}

fn handleTransferEvent(evt: Trb) void {
    const slot_id: u8 = @truncate((evt.control >> 24) & 0xFF);
    const ep_dci: u8 = @truncate((evt.control >> 16) & 0x1F);
    const cc: u8 = @truncate((evt.status >> 24) & 0xFF);

    if (cc != TRB_COMP_SUCCESS and cc != TRB_COMP_SHORT_PACKET) return;

    // Find device by slot_id
    var dev: ?*UsbDevice = null;
    for (0..usb_device_count) |i| {
        if (usb_devices[i].slot_id == slot_id) {
            dev = &usb_devices[i];
            break;
        }
    }
    const d = dev orelse return;
    if (ep_dci != d.hid_ep_dci) return;

    // The TRB parameter points to the data buffer that was filled
    const data_phys = evt.parameter;
    const transferred: u16 = blk: {
        const residual: u16 = @truncate(evt.status & 0xFFFFFF);
        const report_size: u16 = if (d.hid_type == .kbd) 8 else 4;
        break :blk if (report_size > residual) report_size - residual else 0;
    };

    if (transferred == 0) {
        repostHidTransfer(d, data_phys);
        return;
    }

    const buf = paging.physPtr(data_phys);

    switch (d.hid_type) {
        .kbd => handleKeyboardReport(d, buf[0..8]),
        .mouse => handleMouseReport(buf, transferred),
        .none => {},
    }

    // Re-post the transfer
    repostHidTransfer(d, data_phys);
}

fn repostHidTransfer(dev: *UsbDevice, buf_phys: u64) void {
    const report_size: u16 = if (dev.hid_type == .kbd) 8 else 4;
    enqueueHidEp(dev, .{
        .parameter = buf_phys,
        .status = @as(u32, report_size),
        .control = (@as(u32, TRB_NORMAL) << 10) | (1 << 5),
    });
    writeDb(dev.slot_id, @as(u32, dev.hid_ep_dci));
}

// ── Keyboard Report Handling ────────────────────────────────────────

fn handleKeyboardReport(dev: *UsbDevice, report: []const u8) void {
    if (report.len < 8) return;

    // Boot protocol keyboard report:
    // [0] = modifier keys (bitmap)
    // [1] = reserved
    // [2..7] = keycodes (up to 6 simultaneous keys)

    const prev = &dev.prev_kbd_report;

    // Check for released keys (in prev but not in current)
    for (2..8) |pi| {
        const pkey = prev[pi];
        if (pkey == 0) continue;
        var found = false;
        for (2..8) |ci| {
            if (report[ci] == pkey) {
                found = true;
                break;
            }
        }
        if (!found) {
            // Key released
            const evdev = hidToEvdev(pkey);
            if (evdev != 0) keyboard.handleEvdevKey(evdev, 0);
        }
    }

    // Check for pressed keys (in current but not in prev)
    for (2..8) |ci| {
        const ckey = report[ci];
        if (ckey == 0) continue;
        var found = false;
        for (2..8) |pi| {
            if (prev[pi] == ckey) {
                found = true;
                break;
            }
        }
        if (!found) {
            // Key pressed
            const evdev = hidToEvdev(ckey);
            if (evdev != 0) keyboard.handleEvdevKey(evdev, 1);
        }
    }

    // Handle modifier keys
    handleModifiers(dev, prev[0], report[0]);

    // Save current report
    @memcpy(prev, report[0..8]);
}

fn handleModifiers(dev: *UsbDevice, old_mods: u8, new_mods: u8) void {
    _ = dev;
    const changed = old_mods ^ new_mods;
    if (changed == 0) return;

    // Modifier bit → evdev keycode mapping
    const mod_keys = [8]u16{
        29, // bit 0: Left Ctrl → KEY_LEFTCTRL
        42, // bit 1: Left Shift → KEY_LEFTSHIFT
        56, // bit 2: Left Alt → KEY_LEFTALT
        125, // bit 3: Left Meta → KEY_LEFTMETA
        97, // bit 4: Right Ctrl → KEY_RIGHTCTRL
        54, // bit 5: Right Shift → KEY_RIGHTSHIFT
        100, // bit 6: Right Alt → KEY_RIGHTALT
        126, // bit 7: Right Meta → KEY_RIGHTMETA
    };

    for (0..8) |bit| {
        const mask = @as(u8, 1) << @as(u3, @truncate(bit));
        if (changed & mask != 0) {
            const value: u8 = if (new_mods & mask != 0) 1 else 0;
            keyboard.handleEvdevKey(mod_keys[bit], value);
        }
    }
}

// HID Usage ID → Linux evdev keycode
fn hidToEvdev(hid: u8) u16 {
    if (hid >= hid_to_evdev_table.len) return 0;
    return hid_to_evdev_table[hid];
}

const hid_to_evdev_table = [_]u16{
    0, 0, 0, 0, // 0x00-0x03: no event, error
    30, 48, 46, 32, 18, 33, 34, 35, // 0x04-0x0B: a-h
    23, 36, 37, 38, 50, 49, 24, 25, // 0x0C-0x13: i-p
    16, 19, 31, 20, 22, 47, 17, 45, // 0x14-0x1B: q-x
    21, 44, // 0x1C-0x1D: y-z
    2, 3, 4, 5, 6, 7, 8, 9, 10, 11, // 0x1E-0x27: 1-0
    28, // 0x28: Enter
    1, // 0x29: Escape
    14, // 0x2A: Backspace
    15, // 0x2B: Tab
    57, // 0x2C: Space
    12, // 0x2D: -
    13, // 0x2E: =
    26, // 0x2F: [
    27, // 0x30: ]
    43, // 0x31: backslash
    43, // 0x32: non-US # (map to backslash)
    39, // 0x33: ;
    40, // 0x34: '
    41, // 0x35: `
    51, // 0x36: ,
    52, // 0x37: .
    53, // 0x38: /
    58, // 0x39: Caps Lock
    59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88, // 0x3A-0x45: F1-F12
    99, // 0x46: Print Screen
    70, // 0x47: Scroll Lock
    119, // 0x48: Pause
    110, // 0x49: Insert
    102, // 0x4A: Home
    104, // 0x4B: Page Up
    111, // 0x4C: Delete
    107, // 0x4D: End
    109, // 0x4E: Page Down
    106, // 0x4F: Right Arrow
    105, // 0x50: Left Arrow
    108, // 0x51: Down Arrow
    103, // 0x52: Up Arrow
};

// ── Mouse Report Handling ───────────────────────────────────────────

fn handleMouseReport(buf: [*]const u8, len: u16) void {
    if (len < 3) return;
    pushMouseEvent(.{
        .buttons = buf[0],
        .dx = @bitCast(buf[1]),
        .dy = @bitCast(buf[2]),
    });
}

// ── Phase 404: Device Info for /dev/usb ─────────────────────────────

pub fn getDeviceCount() u8 {
    return usb_device_count;
}

pub fn getDevice(idx: u8) ?*const UsbDevice {
    if (idx >= usb_device_count) return null;
    return &usb_devices[idx];
}

pub fn formatDeviceInfo(buf: []u8) usize {
    var pos: usize = 0;
    for (0..usb_device_count) |i| {
        const dev = &usb_devices[i];
        // Format: "PORT SPEED VID:PID CLASS PRODUCT\n"
        pos += fmtStr(buf[pos..], "Port ");
        pos += fmtDec(buf[pos..], dev.port);
        pos += fmtStr(buf[pos..], " ");
        pos += fmtStr(buf[pos..], speedName(dev.speed));
        pos += fmtStr(buf[pos..], " ");
        pos += fmtHex16(buf[pos..], dev.vendor_id);
        pos += fmtStr(buf[pos..], ":");
        pos += fmtHex16(buf[pos..], dev.product_id);
        pos += fmtStr(buf[pos..], " [");
        pos += fmtStr(buf[pos..], usbClassName(dev.class_code, dev.subclass, dev.protocol));
        pos += fmtStr(buf[pos..], "] ");
        if (dev.product_len > 0) {
            pos += fmtStr(buf[pos..], dev.product_str[0..dev.product_len]);
        } else {
            pos += fmtStr(buf[pos..], "Unknown");
        }
        pos += fmtStr(buf[pos..], "\n");
    }
    return pos;
}

fn usbClassName(class: u8, subclass: u8, protocol: u8) []const u8 {
    _ = protocol;
    return switch (class) {
        0x00 => "Device",
        0x01 => "Audio",
        0x02 => "CDC",
        0x03 => switch (subclass) {
            0x01 => "HID Boot",
            else => "HID",
        },
        0x05 => "Physical",
        0x06 => "Image",
        0x07 => "Printer",
        0x08 => "Storage",
        0x09 => "Hub",
        0x0E => "Video",
        0x0F => "Personal Healthcare",
        0xDC => "Diagnostic",
        0xE0 => "Wireless",
        0xEF => "Misc",
        0xFF => "Vendor",
        else => "Unknown",
    };
}

// ── String Formatting Helpers ───────────────────────────────────────

fn fmtStr(buf: []u8, s: []const u8) usize {
    const len = @min(s.len, buf.len);
    @memcpy(buf[0..len], s[0..len]);
    return len;
}

fn fmtDec(buf: []u8, val: anytype) usize {
    const v: u64 = val;
    if (v == 0) {
        if (buf.len > 0) buf[0] = '0';
        return @min(1, buf.len);
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var rem = v;
    while (rem > 0) : (rem /= 10) {
        tmp[n] = @truncate((rem % 10) + '0');
        n += 1;
    }
    const len = @min(n, buf.len);
    for (0..len) |i| {
        buf[i] = tmp[n - 1 - i];
    }
    return len;
}

fn fmtHex16(buf: []u8, val: u16) usize {
    if (buf.len < 4) return 0;
    const hex = "0123456789abcdef";
    buf[0] = hex[@as(u4, @truncate(val >> 12))];
    buf[1] = hex[@as(u4, @truncate(val >> 8))];
    buf[2] = hex[@as(u4, @truncate(val >> 4))];
    buf[3] = hex[@as(u4, @truncate(val))];
    return 4;
}

// ── Utilities ───────────────────────────────────────────────────────

fn zeroPage(phys: u64) void {
    const ptr = paging.physPtr(phys);
    @memset(ptr[0..4096], 0);
}

fn microDelay() void {
    // Simple delay — read a port or just spin
    // On x86_64, reading port 0x80 is ~1μs
    if (@import("builtin").cpu.arch == .x86_64) {
        const cpu = @import("arch/x86_64/cpu.zig");
        _ = cpu.inb(0x80);
    }
}

/// Map a physical MMIO region into the kernel's higher-half page tables.
/// This is needed for BARs above 4 GB which aren't covered by the initial 4GB map.
/// Maps into the higher-half (0xFFFF_8000_... + phys) since physPtr() uses that.
/// The mapping is in the shared kernel PML4 entries 256-511 so it's visible
/// in all address spaces (process page tables shallow-copy these entries).
fn mapMmioRegion(phys_base: u64, size: u64) bool {
    const kernel_pml4 = paging.getKernelPml4();
    const page_size: u64 = 4096;
    var offset: u64 = 0;
    while (offset < size) : (offset += page_size) {
        const phys = (phys_base + offset) & ~@as(u64, 0xFFF);
        const virt = phys +% mem.KERNEL_VIRT_BASE;
        paging.mapPage(kernel_pml4, virt, phys, paging.Flags.WRITABLE | paging.Flags.NO_CACHE) orelse {
            return false;
        };
    }
    return true;
}
