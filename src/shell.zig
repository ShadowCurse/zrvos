const std = @import("std");

const __stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn exit() noreturn {
    _ = syscall3(SYSCALL_EXIT, 0, 0, 0);
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
const SYSCALL_GETCHAR = 1;
const SYSCALL_EXIT = 2;
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

fn getchar() u8 {
    const r = syscall3(SYSCALL_GETCHAR, 0, 0, 0);
    return @truncate(r);
}

const ConsoleWriter = std.io.GenericWriter(void, error{}, console_write);
fn console_write(_: void, string: []const u8) !usize {
    for (string) |c| {
        putchar(c);
    }
    return string.len;
}

fn print(
    comptime format: []const u8,
    args: anytype,
) void {
    const writer: ConsoleWriter = .{ .context = {} };
    writer.print(format, args) catch unreachable;
}

fn exec_cmd(cmd: []const u8) bool {
    if (std.mem.eql(u8, cmd, "hello")) {
        print("Hello {d}\n", .{69});
    } else if (std.mem.eql(u8, cmd, "exit")) {
        return true;
    } else {
        print("Unknown command\n", .{});
    }
    return false;
}

export fn main() void {
    var cmd: [128]u8 = undefined;
    var cmd_cursor: u32 = 0;
    while (true) {
        print("> {s}", .{cmd[0..cmd_cursor]});
        while (true) {
            const c = getchar();
            switch (c) {
                '\r' => {
                    print("\n", .{});
                    if (exec_cmd(cmd[0..cmd_cursor]))
                        return;
                    cmd_cursor = 0;
                    break;
                },
                127 => {
                    if (0 < cmd_cursor) {
                        print("\n", .{});
                        cmd_cursor -= 1;
                        break;
                    }
                },
                else => {
                    if (cmd_cursor == cmd.len) {} else {
                        cmd[cmd_cursor] = c;
                        cmd_cursor += 1;
                        putchar(c);
                    }
                },
            }
        }
    }
}
