const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zish",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Link GNU Readline and SQLite3
    // On macOS, use Homebrew's GNU readline (not libedit)
    const target_info = target.result;
    if (target_info.os.tag == .macos) {
        // Homebrew paths for Apple Silicon and Intel
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/readline/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/readline/lib" });
        exe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/include" });
        exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/lib" });
    }
    exe.linkSystemLibrary("readline");
    exe.linkSystemLibrary("sqlite3");

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zish");
    run_step.dependOn(&run_cmd.step);
}
