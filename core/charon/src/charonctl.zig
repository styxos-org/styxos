const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    // Build command string from args
    var cmd_buf: [1024]u8 = undefined;
    var cmd_len: usize = 0;
    for (args[1..]) |arg| {
        if (cmd_len > 0) {
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        @memcpy(cmd_buf[cmd_len .. cmd_len + arg.len], arg);
        cmd_len += arg.len;
    }

    const sock_path = "/run/charon.sock";

    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(fd);

    var addr = try std.net.Address.initUnix(sock_path);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        std.debug.print("error: cannot connect to charon at {s}\n", .{sock_path});
        std.debug.print("is charon running?\n", .{});
        std.process.exit(1);
    };

    _ = try posix.write(fd, cmd_buf[0..cmd_len]);

    var resp_buf: [4096]u8 = undefined;
    const n = try posix.read(fd, &resp_buf);
    if (n > 0) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(resp_buf[0..n]);
        try stdout.flush();
    }
}

fn printUsage() void {
    var stderr_buf: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(
        \\charonctl - control Charon DNS resolver
        \\
        \\Usage: charonctl <command> [args...]
        \\
        \\Commands:
        \\  flush                     Flush the forwarded-records cache
        \\  evict                     Evict expired cache entries
        \\  stats                     Show cache statistics
        \\  add <name> <TYPE> <value> [ttl]  Add a local zone record
        \\  del <name> <TYPE>         Delete a local zone record
        \\
        \\Examples:
        \\  charonctl flush
        \\  charonctl add myhost.local A 192.168.1.10
        \\  charonctl add myhost.local AAAA fd00::1
        \\  charonctl add alias.local CNAME realhost.local
        \\  charonctl add myhost.local TXT "v=spf1 include:example.com"
        \\  charonctl del myhost.local A
        \\
    ) catch {};
    stderr.flush() catch {};
}
