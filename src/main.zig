const std = @import("std");

const __bss = @extern([*]u8, .{ .name = "__bss" });
const __bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const __stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn boot() linksection(".text.boot") callconv(.Naked) noreturn {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j kernel_main
        :
        : [stack_top] "r" (__stack_top),
    );
}

export fn kernel_main() void {
    var slice: []u8 = undefined;
    slice.ptr = __bss;
    slice.len = @intFromPtr(__bss_end) - @intFromPtr(__bss);
    @memset(slice, 0);

    write_csr("stvec", @intFromPtr(&kernel_entry));

    log("Hello: {d}", .{69});

    unimpl();
}

fn wfi() void {
    asm volatile ("wfi");
}

fn unimpl() void {
    asm volatile ("unimp");
}

const trap_frame = packed struct {
    ra: u32,
    gp: u32,
    tp: u32,
    t0: u32,
    t1: u32,
    t2: u32,
    t3: u32,
    t4: u32,
    t5: u32,
    t6: u32,
    a0: u32,
    a1: u32,
    a2: u32,
    a3: u32,
    a4: u32,
    a5: u32,
    a6: u32,
    a7: u32,
    s0: u32,
    s1: u32,
    s2: u32,
    s3: u32,
    s4: u32,
    s5: u32,
    s6: u32,
    s7: u32,
    s8: u32,
    s9: u32,
    s10: u32,
    s11: u32,
    sp: u32,
};

export fn kernel_entry() align(4) callconv(.Naked) void {
    asm volatile (
        \\csrw sscratch, sp
        \\addi sp, sp, -4 * 32
        \\sw ra,  4 * 0(sp)
        \\sw gp,  4 * 1(sp)
        \\sw tp,  4 * 2(sp)
        \\sw t0,  4 * 3(sp)
        \\sw t1,  4 * 4(sp)
        \\sw t2,  4 * 5(sp)
        \\sw t3,  4 * 6(sp)
        \\sw t4,  4 * 7(sp)
        \\sw t5,  4 * 8(sp)
        \\sw t6,  4 * 9(sp)
        \\sw a0,  4 * 10(sp)
        \\sw a1,  4 * 11(sp)
        \\sw a2,  4 * 12(sp)
        \\sw a3,  4 * 13(sp)
        \\sw a4,  4 * 14(sp)
        \\sw a5,  4 * 15(sp)
        \\sw a6,  4 * 16(sp)
        \\sw a7,  4 * 17(sp)
        \\sw s0,  4 * 18(sp)
        \\sw s1,  4 * 19(sp)
        \\sw s2,  4 * 20(sp)
        \\sw s3,  4 * 21(sp)
        \\sw s4,  4 * 22(sp)
        \\sw s5,  4 * 23(sp)
        \\sw s6,  4 * 24(sp)
        \\sw s7,  4 * 25(sp)
        \\sw s8,  4 * 26(sp)
        \\sw s9,  4 * 27(sp)
        \\sw s10, 4 * 28(sp)
        \\sw s11, 4 * 29(sp)
        \\csrr a0, sscratch
        \\sw a0, 4 * 30(sp)
        \\mv a0, sp
        \\call handle_trap
        \\lw ra,  4 * 0(sp)
        \\lw gp,  4 * 1(sp)
        \\lw tp,  4 * 2(sp)
        \\lw t0,  4 * 3(sp)
        \\lw t1,  4 * 4(sp)
        \\lw t2,  4 * 5(sp)
        \\lw t3,  4 * 6(sp)
        \\lw t4,  4 * 7(sp)
        \\lw t5,  4 * 8(sp)
        \\lw t6,  4 * 9(sp)
        \\lw a0,  4 * 10(sp)
        \\lw a1,  4 * 11(sp)
        \\lw a2,  4 * 12(sp)
        \\lw a3,  4 * 13(sp)
        \\lw a4,  4 * 14(sp)
        \\lw a5,  4 * 15(sp)
        \\lw a6,  4 * 16(sp)
        \\lw a7,  4 * 17(sp)
        \\lw s0,  4 * 18(sp)
        \\lw s1,  4 * 19(sp)
        \\lw s2,  4 * 20(sp)
        \\lw s3,  4 * 21(sp)
        \\lw s4,  4 * 22(sp)
        \\lw s5,  4 * 23(sp)
        \\lw s6,  4 * 24(sp)
        \\lw s7,  4 * 25(sp)
        \\lw s8,  4 * 26(sp)
        \\lw s9,  4 * 27(sp)
        \\lw s10, 4 * 28(sp)
        \\lw s11, 4 * 29(sp)
        \\lw sp,  4 * 30(sp)
        \\sret
    );
}

fn read_csr(comptime name: []const u8) u32 {
    var a: u32 = undefined;
    asm volatile ("csrr %[ret], " ++ name
        : [ret] "=r" (a),
    );
    return a;
}

fn write_csr(comptime name: []const u8, v: u32) void {
    return asm volatile ("csrw " ++ name ++ ", %[arg1]"
        :
        : [arg1] "r" (v),
    );
}

export fn handle_trap(tf: *const trap_frame) void {
    const scause = read_csr("scause");
    const stval = read_csr("stval");
    const user_pc = read_csr("sepc");
    log("trap: scause: 0x{x}, stval: 0x{x}, user_pc: 0x{x}", .{ scause, stval, user_pc });
    log("trap_frame: {any}", .{tf});
    unreachable;
}

const sbiret = extern struct {
    @"error": u32,
    value: u32,
};

fn sbi_call(
    arg0: u32,
    arg1: u32,
    arg2: u32,
    arg3: u32,
    arg4: u32,
    arg5: u32,
    fid: u32,
    eid: u32,
) sbiret {
    asm volatile (
        \\ecall
        :
        : [arg1] "{a0}" (arg0),
          [arg2] "{a1}" (arg1),
          [arg3] "{a2}" (arg2),
          [arg4] "{a3}" (arg3),
          [arg5] "{a4}" (arg4),
          [arg6] "{a5}" (arg5),
          [arg7] "{a6}" (fid),
          [arg8] "{a7}" (eid),
    );
    // zig does not allow multliple returns from assembly
    // read a0 and a1 manually
    const a0 = asm volatile ("mv %[ret], a0"
        : [ret] "={a0}" (-> u32),
    );
    const a1 = asm volatile ("mv %[ret], a1"
        : [ret] "={a1}" (-> u32),
    );
    return .{ .@"error" = a0, .value = a1 };
}

fn sbi_put_char(char: u8) void {
    _ = sbi_call(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
}

const ConsoleWriter = std.io.GenericWriter(void, error{}, console_write);
fn console_write(_: void, string: []const u8) !usize {
    for (string) |c| {
        sbi_put_char(c);
    }
    return string.len;
}

fn log(
    comptime format: []const u8,
    args: anytype,
) void {
    const writer: ConsoleWriter = .{ .context = {} };
    writer.print(format ++ "\n", args) catch unreachable;
}

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, ra: ?usize) noreturn {
    _ = stack_trace;
    _ = ra;

    log("\n!KERNEL PANIC!\n{s}\n", .{message});
    // log("{p} {p}", .{ __debug_info_start, __debug_info_end });
    wfi();
    while (true) {}
}
