/// 8259 PIC (Programmable Interrupt Controller) driver.
///
/// Remaps IRQ 0-7 → vectors 32-39, IRQ 8-15 → vectors 40-47.
/// All IRQs masked initially; unmask individually as drivers register.

const cpu = @import("arch/x86_64/cpu.zig");
const klog = @import("klog.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x11; // init + ICW4 needed
const ICW4_8086: u8 = 0x01; // 8086 mode

pub fn init() void {
    // Save existing masks
    const mask1 = cpu.inb(PIC1_DATA);
    const mask2 = cpu.inb(PIC2_DATA);

    // ICW1: start init sequence (cascade mode, ICW4 needed)
    cpu.outb(PIC1_CMD, ICW1_INIT);
    iowait();
    cpu.outb(PIC2_CMD, ICW1_INIT);
    iowait();

    // ICW2: vector offsets
    cpu.outb(PIC1_DATA, 32); // IRQ 0-7 → vectors 32-39
    iowait();
    cpu.outb(PIC2_DATA, 40); // IRQ 8-15 → vectors 40-47
    iowait();

    // ICW3: cascade wiring
    cpu.outb(PIC1_DATA, 4); // slave on IRQ2
    iowait();
    cpu.outb(PIC2_DATA, 2); // slave identity
    iowait();

    // ICW4: 8086 mode
    cpu.outb(PIC1_DATA, ICW4_8086);
    iowait();
    cpu.outb(PIC2_DATA, ICW4_8086);
    iowait();

    // Mask all IRQs initially
    _ = mask1;
    _ = mask2;
    cpu.outb(PIC1_DATA, 0xFF);
    cpu.outb(PIC2_DATA, 0xFF);

    klog.info("PIC: remapped IRQs 0-15 → vectors 32-47\n");
}

pub fn unmask(irq: u8) void {
    if (irq < 8) {
        const current_mask = cpu.inb(PIC1_DATA);
        cpu.outb(PIC1_DATA, current_mask & ~(@as(u8, 1) << @intCast(irq)));
    } else {
        const slave_irq = irq - 8;
        const current_mask = cpu.inb(PIC2_DATA);
        cpu.outb(PIC2_DATA, current_mask & ~(@as(u8, 1) << @intCast(slave_irq)));
        // Also unmask cascade line (IRQ2) on master
        const master_mask = cpu.inb(PIC1_DATA);
        cpu.outb(PIC1_DATA, master_mask & ~@as(u8, 4));
    }
    klog.debug("PIC: unmasked IRQ ");
    klog.debugDec(irq);
    klog.debug("\n");
}

pub fn mask(irq: u8) void {
    if (irq < 8) {
        const m = cpu.inb(PIC1_DATA);
        cpu.outb(PIC1_DATA, m | (@as(u8, 1) << @intCast(irq)));
    } else {
        const slave_irq = irq - 8;
        const m = cpu.inb(PIC2_DATA);
        cpu.outb(PIC2_DATA, m | (@as(u8, 1) << @intCast(slave_irq)));
    }
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        cpu.outb(PIC2_CMD, 0x20);
    }
    cpu.outb(PIC1_CMD, 0x20);
}

fn iowait() void {
    // Small delay for PIC to process command — write to unused port
    cpu.outb(0x80, 0);
}
