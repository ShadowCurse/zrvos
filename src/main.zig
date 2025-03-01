const std = @import("std");
const Allocator = std.mem.Allocator;

const shell: []const u8 = @embedFile("shell.bin");
const USER_BASE = 0x1000000;

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

    write_csr("stvec", @intFromPtr(&kernel_exception_entry));

    log("Hello: {d}", .{69});

    var a = kernel_bump_allocator.alloc(u8, 2) catch unreachable;
    a[0] = 1;
    a[1] = 2;
    log("Some allocated numbers: {any}", .{a});

    // idle_proc = create_process(0);
    idle_proc = create_process(&.{});
    idle_proc.pid = 0;
    current_proc = idle_proc;
    _ = create_process(shell);
    // _ = create_process(@intFromPtr(&proc_1_entry));
    // _ = create_process(@intFromPtr(&proc_2_entry));
    // print_processes();

    yield();

    @panic("switched to idle process");
}

var current_proc: *Process = undefined;
var idle_proc: *Process = undefined;

// fn proc_1_entry() void {
//     log("starting proc 1", .{});
//     while (true) {
//         sbi_put_char('A');
//         yield();
//         delay();
//     }
// }
// fn proc_2_entry() void {
//     log("starting proc 2", .{});
//     while (true) {
//         sbi_put_char('B');
//         yield();
//         delay();
//     }
// }

const __bss = @extern([*]u8, .{ .name = "__bss" });
const __bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const __stack_top = @extern([*]u8, .{ .name = "__stack_top" });
const __ram_start = @extern([*]align(PAGE_SIZE) u8, .{ .name = "__ram_start" });
const __ram_end = @extern([*]align(PAGE_SIZE) u8, .{ .name = "__ram_end" });
const __kernel_base = @extern([*]align(PAGE_SIZE) u8, .{ .name = "__kernel_base" });

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
        self.cursor += bytes;
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

fn is_aligned(addr: usize, aligment: usize) bool {
    return (addr & (aligment - 1)) == 0;
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

// Page table is just an array of entries.
const PageTable = struct {
    const SATP_SV32 = 1 << 31;

    const Flags = packed struct(u10) {
        valid: bool = false,
        read: bool = false,
        write: bool = false,
        execute: bool = false,
        user: bool = false,
        g: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        rsw: u2 = 0,
    };
    const Entry = packed struct(u32) {
        flags: Flags,
        page_number: packed struct(u22) {
            n_0: u10,
            n_1: u12,
        },

        fn set_page_number(self: *Entry, ptr: *anyopaque) void {
            const u: usize = @intFromPtr(ptr);
            const page_number: u22 = @intCast(u / PAGE_SIZE);
            self.page_number = @bitCast(page_number);
        }

        fn ptr_from_page_number(self: *const Entry, comptime T: type) *T {
            const page_num: usize =
                @intCast(@as(u22, @bitCast(self.page_number)));
            return @ptrFromInt(page_num * PAGE_SIZE);
        }
    };

    const Address = packed struct(usize) {
        page_offse: u12 = 0,
        vpn_0: u10 = 0,
        vpn_1: u10 = 0,
    };

    const Self = @This();

    fn new() *Self {
        const page = kernel_page_allocator.alloc(1);
        @memset(page, 0);
        return @ptrCast(page.ptr);
    }

    fn entries(self: *Self) [*]Entry {
        return @alignCast(@ptrCast(self));
    }

    fn start_page_number(self: *const Self) usize {
        const page_num = @as(usize, @intFromPtr(self)) / PAGE_SIZE;
        return page_num;
    }

    fn map(self: *Self, virt: vaddr, phys: paddr, flags: Flags) void {
        if (!is_aligned(virt, PAGE_SIZE))
            @panic("virt page is not page aligned");

        if (!is_aligned(phys, PAGE_SIZE))
            @panic("phys page is not page aligned");

        const virt_addr: Address = @bitCast(virt);
        const vpn1 = virt_addr.vpn_1;
        const vpn1_entry: *Entry = &self.entries()[vpn1];
        if (!vpn1_entry.flags.valid) {
            const page = kernel_page_allocator.alloc(1);
            vpn1_entry.flags.valid = true;
            vpn1_entry.set_page_number(page.ptr);
        }

        const table_0: *Self = vpn1_entry.ptr_from_page_number(Self);
        const page_num: u22 = @intCast(phys / PAGE_SIZE);
        const vpn0 = virt_addr.vpn_0;
        table_0.entries()[vpn0].flags = flags;
        table_0.entries()[vpn0].flags.valid = true;
        table_0.entries()[vpn0].page_number = @bitCast(page_num);
    }
};

const MAX_PROCESSES = 4;
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
fn print_processes() void {
    for (&processes) |*proc| {
        log("process: pid: {d} state: {any}, sp: 0x{x}", .{ proc.pid, proc.state, proc.sp });
    }
}

const SSTATUS_SPIE = 1 << 5;
fn user_entry() callconv(.Naked) void {
    asm volatile (
        \\csrw sepc, %[sepc]
        \\csrw sstatus, %[sstatus]
        \\sret
        :
        : [sepc] "r" (USER_BASE),
          [sstatus] "r" (SSTATUS_SPIE),
    );
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
    page_table: *PageTable = undefined,

    // During exception handling the first 32 * 4 bytes will be used
    // to store registers. Actual process stack starts from 33 * 4 byte.
    const EXCEPTION_REGS_SIZE = 32;

    const Self = @This();

    fn init(self: *Self, pid: u32, program: []const u8) void {
        self.pid = pid;
        self.state = .runnable;

        var stack_u32: []u32 = undefined;
        stack_u32.ptr = @ptrCast(self.stack.ptr);
        stack_u32.len = self.stack.len / 4;
        // There are EXCEPTION_REGS_SIZE regs to save in case of an exception,
        // so the last one of them is at EXCEPTION_REGS_SIZE - 1.
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 2] = 0; // s11
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 3] = 0; // s10
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 4] = 0; // s9
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 5] = 0; // s8
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 6] = 0; // s7
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 7] = 0; // s6
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 8] = 0; // s5
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 9] = 0; // s4
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 11] = 0; // s3
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 11] = 0; // s2
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 12] = 0; // s1
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 13] = 0; // s0
        stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 14] = @intFromPtr(&user_entry); // ra

        self.sp = @intFromPtr(&stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 14]);

        var page_table = PageTable.new();
        self.page_table = page_table;

        // Map kernel pages
        var phys: paddr = @intFromPtr(__kernel_base);
        const end: paddr = @intFromPtr(__ram_end);
        while (phys < end) : (phys += PAGE_SIZE) {
            page_table.map(phys, phys, .{ .read = true, .write = true, .execute = true });
        }

        // Map user pages
        var offset: u32 = 0;
        while (offset < program.len) : (offset += PAGE_SIZE) {
            const page = kernel_page_allocator.alloc(1);
            const copy_size = @min(PAGE_SIZE, program.len - offset);
            @memcpy(page[0..copy_size], program[offset..][0..copy_size]);
            const user_addr = USER_BASE + offset;
            page_table.map(user_addr, @intFromPtr(page.ptr), .{ .user = true, .read = true, .write = true, .execute = true });
        }
    }

    fn exception_regs_stack_start(self: *Self) *u32 {
        var stack_u32: []u32 = undefined;
        stack_u32.ptr = @ptrCast(self.stack.ptr);
        stack_u32.len = self.stack.len / 4;
        return &stack_u32[stack_u32.len - EXCEPTION_REGS_SIZE - 1];
    }
};

fn create_process(program: []const u8) *Process {
    for (&processes, 0..) |*proc, i| {
        if (proc.state == .unused) {
            proc.init(i + 1, program);
            return proc;
        }
    }

    @panic("No available processes");
}

// Naked functions cannot have inputs. When calling this function `a0` and `a1` registers need
// to contain pointers to the current and next stack pointers.
export fn context_switch() callconv(.Naked) void {
    // This function does generate prolog and epilog even though it does not need it.
    // This is most likely due to generating assembly string at compile time. Maybe
    // new version of compiler will fix this.
    // const regs = &.{
    //     "ra",
    //     "s0",
    //     "s1",
    //     "s2",
    //     "s3",
    //     "s4",
    //     "s5",
    //     "s6",
    //     "s7",
    //     "s8",
    //     "s9",
    //     "s10",
    //     "s11",
    // };
    // asm volatile (save_regs_asm(regs) ++
    //         "sw sp, (a0)\n" ++
    //         "lw sp, (a1)\n" ++
    //         restore_regs_asm(regs) ++
    //         "ret\n");
    //
    asm volatile (
        \\addi sp, sp, -13 * 4
        \\sw ra,  0  * 4(sp)
        \\sw s0,  1  * 4(sp)
        \\sw s1,  2  * 4(sp)
        \\sw s2,  3  * 4(sp)
        \\sw s3,  4  * 4(sp)
        \\sw s4,  5  * 4(sp)
        \\sw s5,  6  * 4(sp)
        \\sw s6,  7  * 4(sp)
        \\sw s7,  8  * 4(sp)
        \\sw s8,  9  * 4(sp)
        \\sw s9,  10 * 4(sp)
        \\sw s10, 11 * 4(sp)
        \\sw s11, 12 * 4(sp)
        \\sw sp, (a0)
        \\lw sp, (a1)
        \\lw ra,  0  * 4(sp)
        \\lw s0,  1  * 4(sp)
        \\lw s1,  2  * 4(sp)
        \\lw s2,  3  * 4(sp)
        \\lw s3,  4  * 4(sp)
        \\lw s4,  5  * 4(sp)
        \\lw s5,  6  * 4(sp)
        \\lw s6,  7  * 4(sp)
        \\lw s7,  8  * 4(sp)
        \\lw s8,  9  * 4(sp)
        \\lw s9,  10 * 4(sp)
        \\lw s10, 11 * 4(sp)
        \\lw s11, 12 * 4(sp)
        \\addi sp, sp, 13 * 4
        \\ret
    );
}

fn yield() void {
    var next = idle_proc;
    for (0..processes.len) |i| {
        const proc = &processes[(current_proc.pid + i) % processes.len];
        if (proc.state == .runnable and
            proc.pid != 0)
        {
            next = proc;
            break;
        }
    }
    if (next == current_proc)
        return;

    // Save pointer to the next process stack in case there
    // is an exception
    asm volatile (
        \\sfence.vma
        \\csrw satp, %[satp]
        \\sfence.vma
        \\ csrw sscratch, %[next_stack]
        :
        : [satp] "r" (PageTable.SATP_SV32 | next.page_table.start_page_number()),
          [next_stack] "r" (next.exception_regs_stack_start()),
    );

    const prev = current_proc;
    current_proc = next;

    // We cannot call naked funcionts directly. Need to use assembly.
    asm volatile (
        \\mv a0, %[prev]
        \\mv a1, %[next]
        \\call context_switch
        :
        : [prev] "r" (&prev.sp),
          [next] "r" (&next.sp),
    );
}

fn print_regs() void {
    inline for (&.{
        "ra",
        "s0",
        "s1",
        "s2",
        "s3",
        "s4",
        "s5",
        "s6",
        "s7",
        "s8",
        "s9",
        "s10",
        "s11",
    }) |r| {
        const ra =
            asm volatile ("mv %[ret], " ++ r
            : [ret] "={a0}" (-> u32),
        );
        log("{s}: 0x{x}", .{ r, ra });
    }
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

export fn kernel_exception_entry() align(4) callconv(.Naked) void {
    asm volatile (
    // Get kernel stack of the process from sscratch (put there by context switch) into sp.
    // The orignal sp from the time of the exception will be in the sscratch.
        \\csrrw sp, sscratch, sp
        \\addi sp, sp, -4 * 31
        // Kernel stack of the process has EXCEPTION_REGS_SIZE * 4 bytes free specificly to
        // save these regs in case of the exception.
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

        // save sp at the time of exception
        \\csrr a0, sscratch
        \\sw a0, 4 * 30(sp)

        // reset a0 to point back at the beginning of the stack
        \\addi a0, sp, 4 * 31
        \\csrw sscratch, a0

        // call handle_trap with sp pointing to the beginning of the `trap_frame` struct
        \\mv a0, sp
        \\call handle_trap

        // restore all regs
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

const SCAUSE_ECALL = 8;
export fn handle_trap(tf: *const trap_frame) void {
    const scause = read_csr("scause");
    const stval = read_csr("stval");
    const user_pc = read_csr("sepc");
    _ = stval;
    if (scause == SCAUSE_ECALL) {
        handle_syscall(tf);
        write_csr("sepc", user_pc + 4);
    } else {
        unreachable;
    }
}

fn handle_syscall(tf: *const trap_frame) void {
    switch (tf.a0) {
        0 => sbi_put_char(@truncate(tf.a1)),
        else => @panic("unknown syscall"),
    }
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
