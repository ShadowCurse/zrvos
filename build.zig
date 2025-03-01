const std = @import("std");

pub fn build(b: *std.Build) void {
    const target_query = std.Target.Query{
        .cpu_arch = std.Target.Cpu.Arch.riscv32,
        .os_tag = std.Target.Os.Tag.freestanding,
        .abi = std.Target.Abi.none,
    };
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "zrvos",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel.setLinkerScript(b.path("src/kernel.ld"));
    kernel.entry = .{ .symbol_name = "boot" };
    b.installArtifact(kernel);

    const shell = b.addExecutable(.{
        .name = "shell",
        .root_source_file = b.path("src/shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell.setLinkerScript(b.path("src/user.ld"));
    shell.entry = .disabled;
    b.installArtifact(shell);

    const elf_to_bin = b.addSystemCommand(&.{
        "llvm-objcopy",
        "--set-section-flags",
        ".bss=alloc,contents",
        "-O",
        "binary",
    });
    elf_to_bin.addArtifactArg(shell);
    const bin = elf_to_bin.addOutputFileArg("shell.bin");

    // to be embeded with @embedFile command
    kernel.root_module.addAnonymousImport("shell.bin", .{
        .root_source_file = bin,
    });

    const run_cmd = b.addSystemCommand(&.{ "bash", "./run.sh" });
    run_cmd.addArtifactArg(kernel);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // const exe_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    //
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_exe_unit_tests.step);
}
