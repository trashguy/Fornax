/// RISC-V 64-bit SMP support — AP boot via SBI HSM + IPI via SBI sIPI.
///
/// Hart discovery: Probes harts 0..MAX_PROBE_HARTS via SBI hart_get_status.
/// Stopped harts are started via sbi_hart_start → ap_entry_asm (entry.S).
/// ap_entry_asm sets SP and SATP, then calls apEntryZig here.
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const klog = @import("../../klog.zig");
const percpu = @import("../../percpu.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");
const process = @import("../../process.zig");
const syscall_entry = @import("syscall_entry.zig");

/// Maximum number of harts to probe via SBI.
const MAX_PROBE_HARTS: u8 = 16;

/// Maps core_id → SBI hartid.
pub var hart_ids: [percpu.MAX_CORES]u32 = [_]u32{0} ** percpu.MAX_CORES;

/// Number of online cores (copied to percpu.cores_online after init).
pub var core_count: u8 = 1;

/// Communication between BSP and booting AP.
var ap_boot_core_id: u8 = 0;
var ap_boot_done: bool = false;

/// Assembly trampoline globals (written by BSP, read by entry.S ap_entry_asm).
extern var ap_stack_top: u64;
extern var ap_bsp_satp: u64;

/// Assembly entry point in entry.S — naked trampoline for AP boot.
extern fn ap_entry_asm() callconv(.naked) noreturn;

/// IPI vector constants (semantic only — SBI sIPI is a single software interrupt,
/// differentiated by tlb_flush_pending flag in percpu).
pub const IPI_SCHEDULE: u8 = 0xFE;
pub const IPI_TLB_SHOOTDOWN: u8 = 0xFD;

/// Initialize SMP: start secondary harts via SBI HSM.
pub fn init() void {
    const boot = @import("boot.zig");
    const bsp_hartid = boot.boot_hartid;

    // Save BSP's SATP for AP trampoline
    ap_bsp_satp = cpu.csrRead(cpu.CSR_SATP);
    hart_ids[0] = @intCast(bsp_hartid);

    klog.info("SMP: BSP is hart ");
    klog.infoDec(@as(u8, @intCast(bsp_hartid)));
    klog.info(", probing via SBI HSM...\n");

    var next_core: u8 = 1;
    var hartid: u32 = 0;
    while (hartid < MAX_PROBE_HARTS and next_core < percpu.MAX_CORES) : (hartid += 1) {
        // Skip the BSP hart
        if (hartid == @as(u32, @intCast(bsp_hartid))) continue;

        // Check if hart exists and is in STOPPED state.
        // If STARTED (0), the hart may still be calling sbi_hart_stop in _start.
        // Wait briefly for it to transition to STOPPED.
        var status = cpu.sbiHartGetStatus(hartid);
        if (status < 0) continue; // Hart doesn't exist
        if (status == 0) {
            // Hart is STARTED — wait for it to stop itself
            var wait: u32 = 0;
            while (status == 0 and wait < 5_000_000) : (wait += 1) {
                cpu.spinHint();
                status = cpu.sbiHartGetStatus(hartid);
            }
        }
        if (status != 1) continue; // Not in STOPPED state (1)

        // Allocate kernel stack (KERNEL_STACK_PAGES contiguous pages)
        const stack_phys = pmm.allocContiguousPages(process.KERNEL_STACK_PAGES) orelse {
            klog.err("SMP: failed to alloc AP kernel stack\n");
            break;
        };
        const phys_stack_top = stack_phys + process.KERNEL_STACK_PAGES * mem.PAGE_SIZE;

        // Set up globals for the assembly trampoline
        ap_stack_top = phys_stack_top;
        percpu.asm_states[next_core].kernel_stack_top = phys_stack_top;

        @atomicStore(u8, &ap_boot_core_id, next_core, .release);
        @atomicStore(bool, &ap_boot_done, false, .release);

        // Ensure all stores are visible before starting the hart
        cpu.fence();

        // Start hart — enters ap_entry_asm (sets SP + SATP, calls apEntryZig)
        const err = cpu.sbiHartStart(hartid, @intFromPtr(&ap_entry_asm), next_core);
        if (err != 0) {
            continue;
        }

        // Wait for AP to signal boot complete (with timeout)
        var timeout: u32 = 0;
        while (!@atomicLoad(bool, &ap_boot_done, .acquire)) {
            cpu.spinHint();
            timeout += 1;
            if (timeout > 50_000_000) {
                klog.err("SMP: hart ");
                klog.errDec(hartid);
                klog.err(" boot timeout\n");
                break;
            }
        }

        if (@atomicLoad(bool, &ap_boot_done, .acquire)) {
            hart_ids[next_core] = hartid;
            klog.info("SMP: Core ");
            klog.infoDec(next_core);
            klog.info(" online (hart ");
            klog.infoDec(hartid);
            klog.info(")\n");
            next_core += 1;
        }
    }

    core_count = next_core;
    percpu.cores_online = core_count;

    klog.info("SMP: ");
    klog.infoDec(core_count);
    klog.info(" core(s) online\n");
}

/// AP Zig-level init — called from ap_entry_asm after SP and SATP are set up.
/// ap_entry_asm already converted SP to higher-half virtual address.
/// a0 = hartid (unused), a1 = core_id (priv_val from sbi_hart_start).
export fn apEntryZig(hartid: u64, priv_val: u64) callconv(.c) noreturn {
    _ = hartid;
    const core_id: u8 = @intCast(priv_val & 0xFF);

    // Update kernel_stack_top to virtual address (SP already virtual from ap_entry_asm)
    const phys_stack_top = percpu.asm_states[core_id].kernel_stack_top;
    const virt_stack_top = phys_stack_top + mem.KERNEL_VIRT_BASE;
    percpu.asm_states[core_id].kernel_stack_top = virt_stack_top;

    // Set TP = &asm_states[core_id] (percpu pointer for S-mode)
    asm volatile ("mv tp, %[v]"
        :
        : [v] "r" (@intFromPtr(&percpu.asm_states[core_id])),
    );

    // Initialize trap vector (STVEC), enable interrupts (SIE), SSTATUS.SUM
    syscall_entry.init();

    // APs should NOT handle external (PLIC) interrupts — only BSP does.
    cpu.csrClear(cpu.CSR_SIE, cpu.SIE_SEIE);

    // SSCRATCH must be 0 in S-mode (trap_entry protocol: 0 = S-mode, percpu = U-mode).
    // trap_return will set SSCRATCH = TP automatically before sret to U-mode.
    cpu.csrWrite(cpu.CSR_SSCRATCH, 0);

    // Set up per-CPU state
    percpu.percpu_array[core_id].core_id = core_id;
    percpu.percpu_array[core_id].online = true;

    // Allocate per-CPU scheduler stack (same size as process kernel stacks)
    if (pmm.allocContiguousPages(process.KERNEL_STACK_PAGES)) |sched_phys| {
        const sched_virt = @intFromPtr(paging.physPtr(sched_phys));
        const sched_top = sched_virt + process.KERNEL_STACK_PAGES * mem.PAGE_SIZE;
        percpu.asm_states[core_id].scheduler_stack_top = sched_top;
    }

    // Arm timer for this hart
    const now = cpu.rdtime();
    cpu.sbiSetTimer(now + 555555);

    // Signal BSP that this AP is ready
    @atomicStore(bool, &ap_boot_done, true, .release);

    // Enter scheduler — run queue empty initially, will steal work
    process.scheduleNext();
}

/// Send an IPI to a specific core. Uses SBI sIPI extension.
pub fn sendIpi(target_core: u8, _: u8) void {
    if (target_core >= core_count) return;
    const hartid = hart_ids[target_core];
    cpu.sbiSendIpi(@as(u64, 1) << @intCast(hartid), 0);
}
