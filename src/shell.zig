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

export fn main() void {
    while (true) {}
}
