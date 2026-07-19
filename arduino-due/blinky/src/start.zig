//! Cortex-M3 startup: vector table, reset handler, and C-runtime init.
//!
//! There is no `_start` and no libc here. On reset the core reads two words
//! from address 0 -- the initial stack pointer and the reset vector -- and
//! branches. Everything a hosted program would get for free (initialised
//! globals, zeroed statics) has to happen in `resetHandler` before any Zig
//! code that touches them runs.

const main = @import("main.zig");

// Symbols defined by link.ld. Only their addresses matter, never their values,
// which is why they are declared as opaque rather than given a real type.
extern var _estack: anyopaque;
extern var _sidata: anyopaque;
extern var _sdata: anyopaque;
extern var _edata: anyopaque;
extern var _sbss: anyopaque;
extern var _ebss: anyopaque;

const Handler = *const fn () callconv(.C) void;

/// The ARMv7-M exception table: 16 words, in the order the core expects them.
/// Laid out as an extern struct so the linker resolves each entry to a real
/// address; an array of integers would need comptime-known addresses, which
/// function pointers are not until link time.
const VectorTable = extern struct {
    initial_sp: *const anyopaque,
    reset: *const fn () callconv(.C) noreturn,
    nmi: Handler,
    hard_fault: Handler,
    mem_manage: Handler,
    bus_fault: Handler,
    usage_fault: Handler,
    reserved0: [4]usize,
    sv_call: Handler,
    debug_mon: Handler,
    reserved1: usize,
    pend_sv: Handler,
    sys_tick: Handler,
};

export const vector_table: VectorTable linksection(".isr_vector") = .{
    .initial_sp = &_estack,
    .reset = &resetHandler,
    .nmi = &defaultHandler,
    .hard_fault = &defaultHandler,
    .mem_manage = &defaultHandler,
    .bus_fault = &defaultHandler,
    .usage_fault = &defaultHandler,
    .reserved0 = .{ 0, 0, 0, 0 },
    .sv_call = &defaultHandler,
    .debug_mon = &defaultHandler,
    .reserved1 = 0,
    .pend_sv = &defaultHandler,
    // SysTick is polled via COUNTFLAG rather than interrupt-driven, so this
    // handler should never fire. It is wired to the trap loop so that if it
    // ever does, the board visibly stops instead of blinking on regardless.
    .sys_tick = &defaultHandler,
};

/// Vector Table Offset Register. The table lives at the start of flash bank 0,
/// not at 0, so point VTOR at it explicitly rather than relying on the boot
/// mirror staying in place.
const SCB_VTOR: *volatile u32 = @ptrFromInt(0xE000ED08);
const FLASH_ORIGIN: u32 = 0x00080000;

export fn resetHandler() callconv(.C) noreturn {
    SCB_VTOR.* = FLASH_ORIGIN;

    // Copy initialised globals from their load address in flash into RAM.
    // Word-at-a-time on purpose: @memcpy would lower to a compiler-rt memcpy
    // call, and this runs before anything is guaranteed to be in place.
    {
        const src: [*]const u32 = @ptrCast(@alignCast(&_sidata));
        const dst: [*]u32 = @ptrCast(@alignCast(&_sdata));
        const words = (@intFromPtr(&_edata) - @intFromPtr(&_sdata)) / @sizeOf(u32);
        var i: usize = 0;
        while (i < words) : (i += 1) dst[i] = src[i];
    }

    // Zero .bss. The linker aligns both bounds to 4, so a word loop covers it exactly.
    {
        const bss: [*]u32 = @ptrCast(@alignCast(&_sbss));
        const words = (@intFromPtr(&_ebss) - @intFromPtr(&_sbss)) / @sizeOf(u32);
        var i: usize = 0;
        while (i < words) : (i += 1) bss[i] = 0;
    }

    main.main();
}

/// Every fault lands here. Spinning rather than resetting is deliberate: a
/// reset loop is exactly the failure mode this project is trying to make
/// visible, so a fault should stop the LED dead instead of producing a blink.
fn defaultHandler() callconv(.C) void {
    while (true) {}
}
