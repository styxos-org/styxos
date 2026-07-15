//! StyxOS init — the first userspace process (PID 1).
//!
//! Responsibilities:
//!   1. Mount the base pseudo-filesystems (/proc, /sys, /dev, cgroup2) and /var.
//!   2. Bind stdin/stdout/stderr to /dev/console.
//!   3. Run the one-shot setup script (/sbin/setup.sh) for network, time, etc.
//!   4. Supervise a console shell and reap orphaned (zombie) processes.
//!   5. On SIGTERM/SIGINT: terminate all processes, sync disks, power off.
//!
//! PID 1 must never exit — the kernel panics if init dies. Therefore main()
//! returns `void` (not `!void`) and every fallible operation is handled
//! inline; nothing is allowed to propagate up and terminate the process.

const std = @import("std");
const config = @import("config");
const linux = std.os.linux;
const posix = std.posix;

const shell_path = "/bin/sh";
const setup_script = "/sbin/setup.sh";

/// Minimal environment passed to every process init spawns.
const default_envp = [_:null]?[*:0]const u8{"PATH=/bin:/sbin:/usr/bin:/usr/sbin"};

/// PID of the supervised console shell; -1 while it is not running.
/// Shared between the main loop and the signal handler, hence atomic.
var shell_pid = std.atomic.Value(posix.pid_t).init(-1);

/// Set by the signal handler when SIGTERM or SIGINT is received.
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Shutdown signal handler. Must stay async-signal-safe: only set a flag and
/// forward the signal; all logging happens in the main loop.
fn handleShutdownSignal(sig: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
    const pid = shell_pid.load(.seq_cst);
    if (pid > 0) {
        // Negative PID: deliver to the shell's whole process group.
        posix.kill(-pid, @intCast(sig)) catch {};
    }
}

/// Wrapper around the raw mount syscall that returns the errno for logging.
fn mountFs(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8) linux.E {
    return posix.errno(linux.mount(source, target, fstype, 0, 0));
}

/// Log a failed mount. E.BUSY is filtered out: it just means the filesystem
/// is already mounted (e.g. devtmpfs when the kernel has DEVTMPFS_MOUNT set).
fn warnMountFailure(out: *std.Io.Writer, target: []const u8, err: linux.E) void {
    if (err == .SUCCESS or err == .BUSY) return;
    out.print("[WARN] mount {s} failed: {s}\n", .{ target, @tagName(err) }) catch {};
}

/// Attach stdin/stdout/stderr to /dev/console. The kernel starts PID 1
/// without usable stdio unless the boot loader arranged otherwise, so this
/// must run before anything is printed. Requires /dev to be mounted.
fn bindConsole() void {
    const fd = posix.open("/dev/console", .{ .ACCMODE = .RDWR }, 0) catch return;
    defer if (fd > 2) posix.close(fd);
    posix.dup2(fd, 0) catch {};
    posix.dup2(fd, 1) catch {};
    posix.dup2(fd, 2) catch {};
}

/// Run /sbin/setup.sh (network, time, ...) and wait for it to finish.
/// Failures are logged but never fatal — the system should still come up
/// enough to give the operator a shell.
fn runSetupScript(out: *std.Io.Writer) void {
    const pid = posix.fork() catch {
        out.writeAll("[WARN] fork failed, skipping " ++ setup_script ++ "\n") catch {};
        return;
    };
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{setup_script};
        posix.execveZ(setup_script, &argv, &default_envp) catch posix.exit(127);
    }
    const result = posix.waitpid(pid, 0);
    if (posix.W.IFEXITED(result.status)) {
        const code = posix.W.EXITSTATUS(result.status);
        if (code != 0) {
            out.print("[WARN] {s} exited with status {d}\n", .{ setup_script, code }) catch {};
        }
    } else {
        out.print("[WARN] {s} was terminated by a signal\n", .{setup_script}) catch {};
    }
}

/// Fork and exec the console shell. Returns the child PID, or -1 if fork
/// failed. The `interactive` build option decides the process setup:
///   - interactive (dev): new session + controlling TTY, so job control
///     (Ctrl+C, Ctrl+Z) works in the shell.
///   - non-interactive (prod): own process group, so init can signal the
///     whole service tree at once via kill(-pid).
fn spawnShell() posix.pid_t {
    const pid = posix.fork() catch return -1;

    if (pid != 0) {
        if (!config.interactive) {
            // Also set the process group from the parent side: a shutdown
            // signal arriving right after fork() can then already be
            // forwarded to the group (closes a startup race).
            posix.setpgid(pid, pid) catch {};
        }
        return pid;
    }

    // Child
    if (config.interactive) {
        // Raw syscall: std.posix.setsid does not compile for libc-less
        // Linux targets in Zig 0.15.2 (errno type mismatch in std).
        _ = linux.syscall0(.setsid);
        _ = linux.ioctl(0, linux.T.IOCSCTTY, 0);
    } else {
        posix.setpgid(0, 0) catch {};
    }

    const argv = [_:null]?[*:0]const u8{shell_path};
    posix.execveZ(shell_path, &argv, &default_envp) catch {
        // Throttle: if /bin/sh is missing, the parent would otherwise
        // respawn us in a tight loop.
        std.Thread.sleep(5 * std.time.ns_per_s);
        posix.exit(1);
    };
}

/// Orderly shutdown: terminate all remaining processes, flush disks, power off.
fn shutdown(out: *std.Io.Writer) void {
    out.writeAll("\n[Init] Shutting down...\n") catch {};

    // From PID 1, kill(-1) signals every process except init itself.
    // SIGTERM first for a graceful stop, SIGKILL after a grace period.
    posix.kill(-1, posix.SIG.TERM) catch {};
    std.Thread.sleep(2 * std.time.ns_per_s);
    posix.kill(-1, posix.SIG.KILL) catch {};

    // Reap everything so no process outlives this point unaccounted for.
    var status: u32 = 0;
    while (true) {
        const rc = linux.wait4(-1, &status, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS, .INTR => continue,
            else => break, // ECHILD: all children reaped.
        }
    }

    out.writeAll("[Init] Syncing disks.\n") catch {};
    posix.sync();

    out.writeAll("[Init] Powering off.\n") catch {};
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
}

pub fn main() void {
    // Base pseudo-filesystems. /dev must exist before the console can be
    // opened, so the results are kept and reported once logging works.
    const proc_err = mountFs("none", "/proc", "proc");
    const sys_err = mountFs("none", "/sys", "sysfs");
    const dev_err = mountFs("none", "/dev", "devtmpfs");

    bindConsole();

    // Unbuffered writer: every message must reach the console immediately.
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    stdout.writeAll("\n=== StyxOS Init (PID 1) ===\n") catch {};
    warnMountFailure(stdout, "/proc", proc_err);
    warnMountFailure(stdout, "/sys", sys_err);
    warnMountFailure(stdout, "/dev", dev_err);

    // Install shutdown handlers. Deliberately without SA_RESTART: the reaper
    // loop relies on wait4() returning EINTR so it can observe the shutdown
    // flag even when the shell ignores the forwarded signal.
    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.INT, &act, null);

    // Control groups (v2) and the writable data partition.
    posix.mkdir("/sys/fs/cgroup", 0o755) catch {};
    warnMountFailure(stdout, "/sys/fs/cgroup", mountFs("none", "/sys/fs/cgroup", "cgroup2"));
    warnMountFailure(stdout, "/var", mountFs("/dev/vda", "/var", "ext4"));

    runSetupScript(stdout);

    stdout.writeAll("Starting shell on console...\n") catch {};

    // Main supervise-and-reap loop. As PID 1, init inherits every orphaned
    // process in the system, so the blocking wait4(-1) below doubles as the
    // zombie reaper.
    while (!shutdown_requested.load(.seq_cst)) {
        if (shell_pid.load(.seq_cst) <= 0) {
            const pid = spawnShell();
            if (pid < 0) {
                // fork() keeps failing — back off instead of spinning.
                std.Thread.sleep(std.time.ns_per_s);
            } else {
                shell_pid.store(pid, .seq_cst);
            }
            // Re-check the shutdown flag before blocking in wait4(): a
            // signal that arrived while spawning would otherwise be missed.
            continue;
        }

        // Deliberately the raw syscall: std.posix.wait4 swallows EINTR and
        // treats ECHILD as unreachable — both are states this loop needs.
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const reaped: posix.pid_t = @intCast(rc);
                if (reaped == shell_pid.load(.seq_cst) and !shutdown_requested.load(.seq_cst)) {
                    stdout.writeAll("[INFO] Shell exited. Respawning...\n") catch {};
                    shell_pid.store(-1, .seq_cst);
                }
            },
            // No children at all — should not happen while the shell runs,
            // but avoid a busy loop and let the next iteration respawn it.
            .CHILD => {
                shell_pid.store(-1, .seq_cst);
                std.Thread.sleep(std.time.ns_per_s);
            },
            // A signal (usually the shutdown request) interrupted wait4 —
            // fall through and re-evaluate the loop condition.
            .INTR => {},
            else => std.Thread.sleep(std.time.ns_per_s),
        }
    }

    shutdown(stdout);
}
