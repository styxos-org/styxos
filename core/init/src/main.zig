const std = @import("std");

pub fn main() !void {
    var buf: [512]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.writeAll("\n=== StyxOS Init (PID 1) ===\n");
    try stdout.flush();

    // 1. Basis-Mounts
    _ = std.os.linux.mount("none", "/proc", "proc", 0, 0);
    _ = std.os.linux.mount("none", "/sys", "sysfs", 0, 0);
    _ = std.os.linux.mount("none", "/dev", "devtmpfs", 0, 0);

    // 2. Cgroups v2 für crun
    _ = std.posix.mkdir("/sys/fs/cgroup", 0o755) catch {};
    _ = std.os.linux.mount("none", "/sys/fs/cgroup", "cgroup2", 0, 0);

    // 3. Die persistente Festplatte einhängen
    const var_mount = std.os.linux.mount("/dev/vda", "/var", "ext4", 0, 0);
    if (var_mount != 0) {
        try stdout.print("[WARN] Konnte /dev/vda nicht auf /var mounten. Code: {}\n", .{var_mount});
    } else {
        try stdout.writeAll("[OK] Persistentes /var gemountet.\n");
    }
    try stdout.flush();

    // 4. Einmaliges Setup-Skript
    var pid = try std.posix.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/sbin/setup.sh" };
        const envp = [_:null]?[*:0]const u8{ "PATH=/bin:/sbin:/usr/bin:/usr/sbin" };

        std.posix.execveZ("/sbin/setup.sh", &argv, &envp) catch {
            std.posix.exit(1);
        };
    }
    _ = std.posix.waitpid(pid, 0);

    try stdout.writeAll("Starte interaktive Shell auf ttyS0...\n");
    try stdout.flush();

    // 5. Shell-Respawn-Loop
    while (true) {
        pid = try std.posix.fork();
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{ "/bin/sh" };
            const envp = [_:null]?[*:0]const u8{ "PATH=/bin:/sbin:/usr/bin:/usr/sbin" };

            std.posix.execveZ("/bin/sh", &argv, &envp) catch {
                std.posix.exit(1);
            };
        }
        _ = std.posix.waitpid(pid, 0);
    }
}
