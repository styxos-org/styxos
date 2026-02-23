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

    //
    // Linenoise -- New in 0.1.0
    //
    exe.addIncludePath(b.path("lib/linenoise"));
    exe.addCSourceFile(.{
        .file = b.path("lib/linenoise/linenoise.c"),
        .flags = &[_][]const u8{
            "-Os", // Optimize Size
        },
    });

    //
    // SQLite3 static -- New in 0.1.0
    //
    exe.addIncludePath(b.path("lib/sqlite3"));
    exe.addCSourceFile(.{
        .file = b.path("lib/sqlite3/sqlite3.c"),
        .flags = &[_][]const u8{
            "-O2",

            // WICHTIG für Shells:
            // Da zish (wahrscheinlich) single-threaded läuft, können wir
            // das ganze Mutex-Locking in SQLite abschalten. Macht es viel schneller.
            "-DSQLITE_THREADSAFE=0",

            // Sicherheit: Keine externen DLLs laden erlauben
            "-DSQLITE_OMIT_LOAD_EXTENSION",

            // Empfohlene Defaults
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        },
    });

    // Linking libC for malloc/free
    exe.linkLibC();

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
