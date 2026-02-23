const std = @import("std");

pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pluto", .{
        .root_source_file = b.path("src/root.zig"),
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "pluto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "pluto", .module = mod },
            },
        }),
    });

    exe.linkSystemLibrary("sqlite3");
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

}
