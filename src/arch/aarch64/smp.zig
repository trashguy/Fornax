/// AArch64 SMP support — AP boot via PSCI CPU_ON + IPI via GIC SGI.
///
/// CPU discovery: Probes MPIDR values 0..MAX_PROBE_CPUS via PSCI AFFINITY_INFO.
/// CPUs in OFF state are started via PSCI CPU_ON → ap_entry_asm (entry.S).
/// ap_entry_asm configures MMU, converts SP to virtual, then calls apEntryZig.
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const gic = @import("gic.zig");
const klog = @import("../../klog.zig");
const percpu = @import("../../percpu.zig");
const pmm = @import("../../pmm.zig");
const mem = @import("../../mem.zig");
const process = @import("../../process.zig");
const syscall_entry = @import("syscall_entry.zig");

/// Maximum CPUs to probe via PSCI (GICv2 supports up to 8).
const MAX_PROBE_CPUS: u8 = 8;

/// Maps core_id → MPIDR Aff0 value.
pub var mpidr_ids: [percpu.MAX_CORES]u8 = [_]u8{0} ** percpu.MAX_CORES;

/// Number of online cores (copied to percpu.cores_online after init).
pub var core_count: u8 = 1;

/// SGI number used for all IPIs (schedule + TLB shootdown).
pub const SGI_IPI: u4 = 0;

/// IPI vector constants (semantic only — differentiated by tlb_flush_pending flag).
pub const IPI_SCHEDULE: u8 = 0xFE;
pub const IPI_TLB_SHOOTDOWN: u8 = 0xFD;

/// Communication between BSP and booting AP.
var ap_boot_done: bool = false;

/// Assembly trampoline globals (written by BSP, read by entry.S ap_entry_asm).
extern var ap_stack_top: u64;
extern var ap_ttbr0: u64;
extern var ap_ttbr1: u64;
extern var ap_mair: u64;
extern var ap_tcr: u64;
extern var ap_sctlr: u64;

/// Assembly entry point in entry.S — naked trampoline for AP boot.
extern fn ap_entry_asm() callconv(.naked) noreturn;

/// Initialize SMP: start secondary CPUs via PSCI CPU_ON.
pub fn init() void {
    // Read BSP's MPIDR
    const bsp_mpidr = cpu.readMpidr() & 0xFF; // Aff0 = core ID on QEMU virt
    mpidr_ids[0] = @intCast(bsp_mpidr);

    // Save BSP's MMU configuration for APs
    ap_ttbr0 = cpu.readTtbr0();
    ap_ttbr1 = cpu.readTtbr1();
    ap_mair = cpu.readMair();
    ap_tcr = cpu.readTcr();
    ap_sctlr = cpu.readSctlr();

    klog.info("SMP: BSP is CPU ");
    klog.infoDec(@as(u8, @intCast(bsp_mpidr)));
    klog.info(", probing via PSCI...\n");

    var next_core: u8 = 1;
    var mpidr: u8 = 0;
    while (mpidr < MAX_PROBE_CPUS and next_core < percpu.MAX_CORES) : (mpidr += 1) {
        // Skip BSP
        if (mpidr == @as(u8, @intCast(bsp_mpidr))) continue;

        // Query CPU state via PSCI AFFINITY_INFO
        const status = cpu.psciAffinityInfo(@as(u64, mpidr));
        // 0=ON, 1=OFF, 2=ON_PENDING, negative=error
        if (status != 1) continue; // Not in OFF state

        // Allocate kernel stack
        const stack_phys = pmm.allocContiguousPages(process.KERNEL_STACK_PAGES) orelse {
            klog.err("SMP: failed to alloc AP kernel stack\n");
            break;
        };
        const phys_stack_top = stack_phys + process.KERNEL_STACK_PAGES * mem.PAGE_SIZE;

        // Set up globals for the assembly trampoline
        ap_stack_top = phys_stack_top;
        percpu.asm_states[next_core].kernel_stack_top = phys_stack_top;

        @atomicStore(bool, &ap_boot_done, false, .release);

        // Memory barrier to ensure all stores are visible
        cpu.dsb();
        cpu.isb();

        // Start CPU — PSCI CPU_ON with physical address of ap_entry_asm.
        // On aarch64 UEFI, PE symbols are at UEFI-loaded physical addresses
        const entry_phys = @intFromPtr(&ap_entry_asm);
        const err = cpu.psciCpuOn(@as(u64, mpidr), entry_phys, @as(u64, next_core));
        if (err != 0) {
            klog.debug("SMP: PSCI CPU_ON failed for MPIDR ");
            klog.debugDec(mpidr);
            klog.debug(" (err=");
            klog.debugHex(@as(u64, @bitCast(err)));
            klog.debug(")\n");
            continue;
        }

        // Wait for AP to signal boot complete
        var timeout: u32 = 0;
        while (!@atomicLoad(bool, &ap_boot_done, .acquire)) {
            cpu.spinHint();
            timeout += 1;
            if (timeout > 50_000_000) {
                klog.err("SMP: CPU ");
                klog.errDec(mpidr);
                klog.err(" boot timeout\n");
                break;
            }
        }

        if (@atomicLoad(bool, &ap_boot_done, .acquire)) {
            mpidr_ids[next_core] = mpidr;
            klog.info("SMP: Core ");
            klog.infoDec(next_core);
            klog.info(" online (MPIDR ");
            klog.infoDec(mpidr);
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

/// AP Zig-level init — called from ap_entry_asm after MMU is on and SP is virtual.
export fn apEntryZig(core_id_raw: u64) callconv(.c) noreturn {
    const core_id: u8 = @intCast(core_id_raw & 0xFF);

    // Update kernel_stack_top to virtual address (SP already virtual from ap_entry_asm)
    const phys_stack_top = percpu.asm_states[core_id].kernel_stack_top;
    const virt_stack_top = phys_stack_top + mem.KERNEL_VIRT_BASE;
    percpu.asm_states[core_id].kernel_stack_top = virt_stack_top;

    // Set TPIDR_EL1 = &asm_states[core_id] (per-CPU pointer for EL1)
    cpu.writeTpidrEl1(@intFromPtr(&percpu.asm_states[core_id]));

    // Initialize trap vector (VBAR_EL1 + SPSel)
    syscall_entry.init();

    // Initialize per-CPU GIC interface (distributor already init'd by BSP)
    gic.initCpuInterface();
    // Enable timer PPI for this core
    gic.enableTimerPpi();

    // Arm timer for this core
    const freq = cpu.readCntfrq();
    const ticks_per_ms = freq / 1000;
    const timer_interval = ticks_per_ms * 55; // ~55ms, matching BSP timer interval
    cpu.writeCntpTval(@intCast(timer_interval));
    cpu.writeCntpCtl(1); // enable, unmask

    // Set up per-CPU state
    percpu.percpu_array[core_id].core_id = core_id;
    percpu.percpu_array[core_id].online = true;

    // Allocate per-CPU scheduler stack (same size as process kernel stacks)
    if (pmm.allocContiguousPages(process.KERNEL_STACK_PAGES)) |sched_phys| {
        const sched_virt = @intFromPtr(paging.physPtr(sched_phys));
        const sched_top = sched_virt + process.KERNEL_STACK_PAGES * mem.PAGE_SIZE;
        percpu.asm_states[core_id].scheduler_stack_top = sched_top;
    }

    // Enable interrupts for this core
    cpu.enableInterrupts();

    // Signal BSP that this AP is ready
    @atomicStore(bool, &ap_boot_done, true, .release);

    // Enter scheduler — run queue empty initially, will steal work
    process.scheduleNext();
}

/// Send an IPI to a specific core via GIC SGI.
pub fn sendIpi(target_core: u8, _: u8) void {
    if (target_core >= core_count) return;
    // GICv2 target mask: bit N = CPU N (max 8 CPUs)
    const target_mask: u8 = @as(u8, 1) << @intCast(target_core);
    gic.sendSgi(SGI_IPI, target_mask);
}
