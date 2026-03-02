const std = @import("std");

var child_pid: std.posix.pid_t = -1;
var is_shutting_down: bool = false;

fn sig_handler(sig: c_int) callconv(.c) void {
    is_shutting_down = true;
    if (child_pid > 0) {
        _ = std.posix.kill(-child_pid, @intCast(sig)) catch {};
    }
}

// WICHTIG: void statt !void. PID 1 crasht nicht.
pub fn main() void {
    // Base Mounts
    _ = std.os.linux.mount("none", "/proc", "proc", 0, 0);
    _ = std.os.linux.mount("none", "/sys", "sysfs", 0, 0);
    _ = std.os.linux.mount("none", "/dev", "devtmpfs", 0, 0);

    // Create device for STDIN, STDOUT and STDERR
    const O_RDWR: usize = 2;
    const console_fd = std.os.linux.syscall3(std.os.linux.SYS.open, @intFromPtr("/dev/console\x00"), O_RDWR, 0);

    if (console_fd >= 0) {
        _ = std.os.linux.syscall2(std.os.linux.SYS.dup2, console_fd, 0); // stdin
        _ = std.os.linux.syscall2(std.os.linux.SYS.dup2, console_fd, 1); // stdout
        _ = std.os.linux.syscall2(std.os.linux.SYS.dup2, console_fd, 2); // stderr
        if (console_fd > 2) {
            _ = std.os.linux.syscall1(std.os.linux.SYS.close, console_fd);
        }
    }

    var w = std.fs.File.stdout().writer(&.{});
    const stdout = &w.interface;

    // catch {} schluckt den Fehler, falls die Konsole wider Erwarten nicht bereit ist
    stdout.writeAll("\n=== StyxOS Init (PID 1) ===\n") catch {};

    // Catch Signals
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = sig_handler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Mounting Cgroups & /var
    _ = std.posix.mkdir("/sys/fs/cgroup", 0o755) catch {};
    _ = std.os.linux.mount("none", "/sys/fs/cgroup", "cgroup2", 0, 0);

    const var_mount = std.os.linux.mount("/dev/vda", "/var", "ext4", 0, 0);
    if (var_mount != 0) {
        stdout.print("[WARN] Failed to mount /dev/vda. Code: {d}\n", .{var_mount}) catch {};
    }

    // Run Setup Script (Network, Time, etc.)
    // fork() kann fehlschlagen, wir fangen es mit catch -1 ab
    const setup_pid = std.posix.fork() catch -1;
    if (setup_pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/sbin/setup.sh", null };
        const envp = [_:null]?[*:0]const u8{ "PATH=/bin:/sbin:/usr/bin:/usr/sbin", null };
        std.posix.execveZ("/sbin/setup.sh", &argv, &envp) catch {
            std.posix.exit(1);
        };
    } else if (setup_pid > 0) {
        // Nur warten, wenn fork() erfolgreich war
        _ = std.posix.waitpid(setup_pid, 0);
    }

    stdout.writeAll("Starting interactive shell on console...\n") catch {};

    // Reaper-Loop with wait4 Syscall
    while (!is_shutting_down) {
        if (child_pid <= 0) {
            child_pid = std.posix.fork() catch -1;

            // Verhindert wildes Spinning, falls fork() dauerhaft fehlschlägt
            if (child_pid < 0) {
                std.Thread.sleep(std.time.ns_per_s);
                continue;
            }

            if (child_pid == 0) {
                _ = std.posix.setpgid(0, 0) catch {};
                const argv = [_:null]?[*:0]const u8{ "/bin/sh", null };
                const envp = [_:null]?[*:0]const u8{ "PATH=/bin:/sbin:/usr/bin:/usr/sbin", null };

                std.posix.execveZ("/bin/sh", &argv, &envp) catch {
                    std.Thread.sleep(std.time.ns_per_s * 5);
                    std.posix.exit(1);
                };
            }
        }

        var status: u32 = 0;
        const rc = std.os.linux.wait4(-1, &status, 0, null);

        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const reaped_pid: std.posix.pid_t = @intCast(rc);
                if (reaped_pid == child_pid) {
                    if (!is_shutting_down) {
                        stdout.writeAll("[INFO] Shell exited. Respawning...\n") catch {};
                        child_pid = -1;
                    }
                }
            },
            .CHILD => {
                // ECHILD: No Zombies, just take a nap.
                std.Thread.sleep(std.time.ns_per_s);
            },
            else => continue, // Ignore EINTR
        }
    }

    // Shutdown Sequence
    stdout.writeAll("\n[Init] Shutting down... syncing disks.\n") catch {};
    _ = std.os.linux.syscall0(std.os.linux.SYS.sync);

    // QEMU/Kernel clean exit
    stdout.writeAll("[Init] Powering off.\n") catch {};
    _ = std.os.linux.syscall4(std.os.linux.SYS.reboot, 0xfee1dead, 672274793, 0x4321fedc, 0);
}
