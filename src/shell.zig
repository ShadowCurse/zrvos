const std = @import("std");

const __stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn exit() noreturn {
    while (true) {}
}

export fn start() linksection(".text.start") callconv(.Naked) void {
    asm volatile (
        \\mv sp, %[stack_top]
        \\call main
        \\call exit
        :
        : [stack_top] "r" (__stack_top),
    );
}

const SYSCALL_PUTCHAR = 0;
fn syscall3(n: u32, arg0: u32, arg1: u32, arg2: u32) u32 {
    return asm volatile (
        \\ecall
        : [ret] "={a0}" (-> u32),
        : [number] "{a0}" (n),
          [arg1] "{a1}" (arg0),
          [arg2] "{a2}" (arg1),
          [arg3] "{a3}" (arg2),
    );
}

fn putchar(char: u8) void {
    _ = syscall3(SYSCALL_PUTCHAR, char, 0, 0);
}

const ConsoleWriter = std.io.GenericWriter(void, error{}, console_write);
fn console_write(_: void, string: []const u8) !usize {
    for (string) |c| {
        putchar(c);
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

export fn main() void {
    log("Hello from userspace: {d}", .{69});
}
