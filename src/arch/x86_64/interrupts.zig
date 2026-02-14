const console = @import("../../console.zig");
const serial = @import("../../serial.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const supervisor = @import("../../supervisor.zig");
const process = @import("../../process.zig");

const exception_names = [_][]const u8{
    "Division Error", // 0
    "Debug", // 1
    "NMI", // 2
    "Breakpoint", // 3
    "Overflow", // 4
    "Bound Range Exceeded", // 5
    "Invalid Opcode", // 6
    "Device Not Available", // 7
    "Double Fault", // 8
    "Coprocessor Segment", // 9
    "Invalid TSS", // 10
    "Segment Not Present", // 11
    "Stack-Segment Fault", // 12
    "General Protection Fault", // 13
    "Page Fault", // 14
    "Reserved", // 15
    "x87 Floating-Point", // 16
    "Alignment Check", // 17
    "Machine Check", // 18
    "SIMD Floating-Point", // 19
    "Virtualization", // 20
    "Control Protection", // 21
    "Reserved", // 22
    "Reserved", // 23
    "Reserved", // 24
    "Reserved", // 25
    "Reserved", // 26
    "Reserved", // 27
    "Hypervisor Injection", // 28
    "VMM Communication", // 29
    "Security Exception", // 30
    "Reserved", // 31
};

pub fn handleException(frame: *idt.ExceptionFrame) void {
    // Check if the fault came from user mode (RPL=3 in CS)
    const from_user = (frame.cs & 3) == 3;

    if (from_user) {
        // User-mode fault — kill the process, don't panic the kernel
        serial.puts("\n--- USER EXCEPTION ---\n");
        serial.puts("Vector: ");
        serial.putDec(frame.vector);
        serial.puts(" (");
        if (frame.vector < 32) {
            serial.puts(exception_names[frame.vector]);
        }
        serial.puts(")\nRIP: ");
        serial.putHex(frame.rip);
        serial.puts("\n");

        if (frame.vector == 14) {
            serial.puts("CR2: ");
            serial.putHex(cpu.readCr2());
            serial.puts("\n");
        }

        // Get the faulting process
        if (process.getCurrent()) |proc| {
            const pid = proc.pid;

            // Try supervisor restart for supervised services
            _ = supervisor.handleProcessFault(pid);

            // Whether supervised or not, mark the process dead
            proc.state = .dead;

            console.puts("[Process ");
            console.putDec(pid);
            console.puts(" faulted: ");
            if (frame.vector < 32) {
                console.puts(exception_names[frame.vector]);
            }
            console.puts("]\n");

            // Schedule the next process
            process.scheduleNext();
        } else {
            // No current process — shouldn't happen, but handle gracefully
            console.puts("[User fault with no current process]\n");
            cpu.halt();
        }
    } else {
        // Kernel-mode fault — always fatal
        serial.puts("\n--- KERNEL EXCEPTION (serial) ---\n");
        serial.puts("Vector: ");
        serial.putDec(frame.vector);
        serial.puts(" Err: ");
        serial.putHex(frame.error_code);
        serial.puts(" RIP: ");
        serial.putHex(frame.rip);
        serial.puts(" CS: ");
        serial.putHex(frame.cs);
        serial.puts(" RFLAGS: ");
        serial.putHex(frame.rflags);
        serial.puts(" RSP: ");
        serial.putHex(frame.rsp);
        serial.puts(" SS: ");
        serial.putHex(frame.ss);
        serial.puts("\n");
        console.puts("\n--- KERNEL EXCEPTION ---\n");

        if (frame.vector < 32) {
            console.puts("Type: ");
            console.puts(exception_names[frame.vector]);
            console.puts(" (#");
            console.putDec(frame.vector);
            console.puts(")\n");
        } else {
            console.puts("Vector: ");
            console.putDec(frame.vector);
            console.puts("\n");
        }

        console.puts("Error code: ");
        console.putHex(frame.error_code);
        console.puts("\nRIP: ");
        console.putHex(frame.rip);
        console.puts("\nRSP: ");
        console.putHex(frame.rsp);
        console.puts("\nRFLAGS: ");
        console.putHex(frame.rflags);
        console.puts("\n");

        if (frame.vector == 14) {
            console.puts("CR2: ");
            console.putHex(cpu.readCr2());
            console.puts("\n");
        }

        console.puts("--- Halting ---\n");
        cpu.halt();
    }
}

pub fn init() void {
    gdt.init();
    idt.init();
    paging.init();
    console.puts("x86_64: GDT + IDT + paging initialized\n");
}
