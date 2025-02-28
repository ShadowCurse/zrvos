const std = @import("std");
const Allocator = std.mem.Allocator;

const PAGE_SIZE = 4096;
const paddr = usize;
const vaddr = usize;

export fn boot() linksection(".text.boot") callconv(.Naked) noreturn {
    asm volatile (
        \\mv sp, %[stack_top]
        \\j kernel_main
        :
        : [stack_top] "r" (__stack_top),
    );
}

export fn kernel_main() void {
    zero_bss();
    init_kernel_allocators();
    init_processes();

    write_csr("stvec", @intFromPtr(&kernel_entry));

    log("Hello: {d}", .{69});

    var a = kernel_bump_allocator.alloc(u8, 2) catch unreachable;
    a[0] = 1;
    a[1] = 2;
    log("Some allocated numbers: {any}", .{a});

    proc_1 = create_process(@intFromPtr(&proc_1_entry));
    proc_2 = create_process(@intFromPtr(&proc_2_entry));
    proc_1_entry();

    unimpl();
}

var proc_1: *Process = undefined;
var proc_2: *Process = undefined;

fn proc_1_entry() void {
    log("starting proc 1", .{});
    while (true) {
        sbi_put_char('A');
        context_switch(&proc_1.sp, &proc_2.sp);
        delay();
    }
}
fn proc_2_entry() void {
    log("starting proc 2", .{});
    while (true) {
        sbi_put_char('B');
        context_switch(&proc_2.sp, &proc_1.sp);
        delay();
    }
}

const __bss = @extern([*]u8, .{ .name = "__bss" });
const __bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const __stack_top = @extern([*]u8, .{ .name = "__stack_top" });
const __ram_start = @extern([*]align(PAGE_SIZE) u8, .{ .name = "__ram_start" });
const __ram_end = @extern([*]align(PAGE_SIZE) u8, .{ .name = "__ram_end" });

var kernel_page_allocator: KernelPageAllocator = undefined;
const KernelPageAllocator = struct {
    cursor: paddr,

    const Self = @This();

    fn init() Self {
        return .{
            .cursor = @intFromPtr(__ram_start),
        };
    }

    fn alloc(self: *Self, n: u32) []align(PAGE_SIZE) u8 {
        const bytes = n * PAGE_SIZE;
        if (@intFromPtr(__ram_end) < self.cursor + n)
            unreachable;
        var slice: []align(PAGE_SIZE) u8 = undefined;
        slice.ptr = @ptrFromInt(self.cursor);
        slice.len = bytes;
        return slice;
    }
};

var kernel_bump_allocator_impl: std.heap.FixedBufferAllocator = undefined;
const kernel_bump_allocator = kernel_bump_allocator_impl.allocator();

fn kernel_ram_slice() []align(PAGE_SIZE) u8 {
    var s: []align(PAGE_SIZE) u8 = undefined;
    s.ptr = __ram_start;
    s.len = @intFromPtr(__ram_end) - @intFromPtr(__ram_start);
    return s;
}

fn init_kernel_allocators() void {
    kernel_page_allocator = KernelPageAllocator.init();
    const bump_allocator_memory = kernel_page_allocator.alloc(1);
    kernel_bump_allocator_impl = std.heap.FixedBufferAllocator.init(bump_allocator_memory);
}

fn zero_bss() void {
    var slice: []u8 = undefined;
    slice.ptr = __bss;
    slice.len = @intFromPtr(__bss_end) - @intFromPtr(__bss);
    @memset(slice, 0);
}

fn delay() void {
    for (0..30000000) |_| {
        asm volatile ("nop");
    }
}

fn wfi() void {
    asm volatile ("wfi");
}

fn unimpl() void {
    asm volatile ("unimp");
}

fn save_regs_asm(comptime regs: []const []const u8) []const u8 {
    comptime var s: []const u8 = std.fmt.comptimePrint("addi sp, sp, -4 * {d}\n", .{regs.len});
    inline for (regs, 0..) |reg, i| {
        s = s ++ std.fmt.comptimePrint("sw {s}, {d} * 4(sp)\n", .{ reg, i });
    }
    return s;
}

fn restore_regs_asm(comptime regs: []const []const u8) []const u8 {
    comptime var s: []const u8 = &.{};
    inline for (regs, 0..) |reg, i| {
        s = s ++ std.fmt.comptimePrint("lw {s}, {d} * 4(sp)\n", .{ reg, i });
    }
    s = s ++ std.fmt.comptimePrint("addi sp, sp, 4 * {d}\n", .{regs.len});
    return s;
}

const MAX_PROCESSES = 32;
var processes: [MAX_PROCESSES]Process = undefined;
fn init_processes() void {
    for (&processes) |*proc| {
        const stack = kernel_page_allocator.alloc(1);
        @memset(stack, 0);
        proc.* = .{
            .stack = stack,
        };
    }
}
const ProcessState = enum {
    unused,
    runnable,
};
const Process = struct {
    pid: u32 = 0,
    state: ProcessState = .unused,
    sp: vaddr = 0,
    stack: []align(PAGE_SIZE) u8,

    const Self = @This();

    fn init(self: *Self, pid: u32, pc: vaddr) void {
        self.pid = pid;
        self.state = .runnable;

        var stack_u32: []u32 = undefined;
        stack_u32.ptr = @ptrCast(self.stack.ptr);
        stack_u32.len = self.stack.len / 4;
        stack_u32[stack_u32.len - 1] = 0; // s11
        stack_u32[stack_u32.len - 2] = 0; // s10
        stack_u32[stack_u32.len - 3] = 0; // s9
        stack_u32[stack_u32.len - 4] = 0; // s8
        stack_u32[stack_u32.len - 5] = 0; // s7
        stack_u32[stack_u32.len - 6] = 0; // s6
        stack_u32[stack_u32.len - 7] = 0; // s5
        stack_u32[stack_u32.len - 8] = 0; // s4
        stack_u32[stack_u32.len - 9] = 0; // s3
        stack_u32[stack_u32.len - 10] = 0; // s2
        stack_u32[stack_u32.len - 11] = 0; // s1
        stack_u32[stack_u32.len - 12] = 0; // s0
        stack_u32[stack_u32.len - 13] = pc; // ra

        self.sp = @intFromPtr(&stack_u32[stack_u32.len - 13]);
    }
};

fn create_process(pc: vaddr) *Process {
    for (&processes, 0..) |*proc, i| {
        if (proc.state == .unused) {
            proc.init(i + 1, pc);
            return proc;
        }
    }

    panic("No available processes", null, null);
}

// This function does generate prolog and epilog even though it does not need it.
// This is most likely due to generating assembly string at compile time. Maybe
// new version of compiler will fix this.
noinline fn context_switch(noalias prev_sp: *vaddr, noalias next_sp: *vaddr) void {
    const regs = &.{ "ra", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11" };
    asm volatile (save_regs_asm(regs) ++
            "sw sp, (%[arg1])\n" ++
            "lw sp, (%[arg2])\n" ++
            restore_regs_asm(regs) ++
            "ret\n"
        :
        : [arg1] "r" (prev_sp),
          [arg2] "r" (next_sp),
    );
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
