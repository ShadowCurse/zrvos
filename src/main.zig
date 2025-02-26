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

    log("Hello: {d}", .{69});

    var a: u8 = 255;
    a += 1;

    wfi();
}

fn wfi() void {
    asm volatile ("wfi");
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
