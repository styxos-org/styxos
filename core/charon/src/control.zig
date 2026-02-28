const std = @import("std");
const posix = std.posix;
const zone = @import("zone.zig");
const dns = @import("dns.zig");

pub const ControlSocket = struct {
    zonedb: *zone.ZoneDb,
    sock_path: []const u8,
    sock_fd: ?posix.socket_t,

    pub fn init(zonedb: *zone.ZoneDb, sock_path: []const u8) ControlSocket {
        return .{
            .zonedb = zonedb,
            .sock_path = sock_path,
            .sock_fd = null,
        };
    }

    pub fn start(self: *ControlSocket) !void {
        // Remove stale socket
        std.fs.cwd().deleteFile(self.sock_path) catch {};

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        self.sock_fd = fd;

        var addr = std.net.Address.initUnix(self.sock_path) catch return error.InvalidPath;
        try posix.bind(fd, &addr.any, addr.getOsSockLen());
        try posix.listen(fd, 5);

        std.log.info("control socket listening on {s}", .{self.sock_path});
    }

    pub fn deinit(self: *ControlSocket) void {
        if (self.sock_fd) |fd| {
            posix.close(fd);
        }
        std.fs.cwd().deleteFile(self.sock_path) catch {};
    }

    /// Non-blocking poll for control commands
    pub fn poll(self: *ControlSocket) !void {
        const fd = self.sock_fd orelse return;

        const client_fd = posix.accept(fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        defer posix.close(client_fd);

        var buf: [1024]u8 = undefined;
        const n = posix.read(client_fd, &buf) catch return;
        if (n == 0) return;

        const cmd = std.mem.trim(u8, buf[0..n], " \t\r\n");
        const response = self.handleCommand(cmd);

        _ = posix.write(client_fd, response) catch {};
    }

    fn handleCommand(self: *ControlSocket, cmd: []const u8) []const u8 {
        if (std.mem.eql(u8, cmd, "flush")) {
            self.zonedb.flushCache() catch return "ERR: flush failed\n";
            return "OK: cache flushed\n";
        }

        if (std.mem.eql(u8, cmd, "stats")) {
            // Simple stats response
            _ = self.zonedb.cacheCount() catch return "ERR: stats failed\n";
            return "OK: stats retrieved\n";
        }

        if (std.mem.eql(u8, cmd, "evict")) {
            self.zonedb.evictExpired() catch return "ERR: evict failed\n";
            return "OK: expired entries evicted\n";
        }

        if (std.mem.startsWith(u8, cmd, "add ")) {
            return self.handleAdd(cmd[4..]);
        }

        if (std.mem.startsWith(u8, cmd, "del ")) {
            return self.handleDel(cmd[4..]);
        }

        return "ERR: unknown command. Available: flush, stats, evict, add <name> <type> <value> [ttl], del <name> <type>\n";
    }

    fn handleAdd(self: *ControlSocket, args: []const u8) []const u8 {
        var parts = std.mem.tokenizeAny(u8, args, " \t");
        const name = parts.next() orelse return "ERR: usage: add <name> <type> <value> [ttl]\n";
        const rtype_str = parts.next() orelse return "ERR: usage: add <name> <type> <value> [ttl]\n";
        const rdata = parts.next() orelse return "ERR: usage: add <name> <type> <value> [ttl]\n";
        const ttl_str = parts.next();

        const rtype = dns.RecordType.fromString(rtype_str) orelse return "ERR: unknown record type\n";
        const ttl: u32 = if (ttl_str) |ts| std.fmt.parseInt(u32, ts, 10) catch 0 else 0;

        self.zonedb.addRecord(name, rtype, rdata, ttl) catch return "ERR: failed to add record\n";
        return "OK: record added\n";
    }

    fn handleDel(self: *ControlSocket, args: []const u8) []const u8 {
        var parts = std.mem.tokenizeAny(u8, args, " \t");
        const name = parts.next() orelse return "ERR: usage: del <name> <type>\n";
        const rtype_str = parts.next() orelse return "ERR: usage: del <name> <type>\n";

        const rtype = dns.RecordType.fromString(rtype_str) orelse return "ERR: unknown record type\n";

        self.zonedb.deleteLocalRecord(name, rtype) catch return "ERR: failed to delete record\n";
        return "OK: record deleted\n";
    }
};
