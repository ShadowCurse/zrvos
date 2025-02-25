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
    while (true) {}
}
