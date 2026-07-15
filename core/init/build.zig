const std = @import("std");

pub fn build(b: *std.Build) void {
    // init always targets x86_64 Linux as a static musl binary: it runs in
    // the earliest boot stage, where no dynamic loader is available.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
        .cpu_model = .{ .explicit = std.Target.Cpu.Model.generic(.x86_64) },
    });

    const optimize = b.standardOptimizeOption(.{});

    // Whether the console shell gets its own session and controlling TTY
    // (job control / Ctrl+C). Handy for development in QEMU; production
    // builds put the shell in a plain process group instead so init can
    // signal the whole service tree.
    const interactive = b.option(
        bool,
        "interactive",
        "Give the console shell a controlling TTY (default: true for Debug builds)",
    ) orelse (optimize == .Debug);

    const options = b.addOptions();
    options.addOption(bool, "interactive", interactive);

    const exe = b.addExecutable(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = options.createModule() },
            },
        }),
    });

    b.installArtifact(exe);
}
