const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");

pub const Forwarder = struct {
    upstream: config.Upstream,
    timeout_ms: u32,

    pub fn init(upstream: config.Upstream, timeout_ms: u32) Forwarder {
        return .{
            .upstream = upstream,
            .timeout_ms = timeout_ms,
        };
    }

    /// Forward a raw DNS query to the upstream resolver and return the response
    pub fn forward(self: *const Forwarder, query: []const u8, response_buf: []u8) !usize {
        const addrs = self.upstream.getAddresses();

        // Try primary, then secondary
        return self.forwardTo(addrs.primary, query, response_buf) catch
            self.forwardTo(addrs.secondary, query, response_buf);
    }

    fn forwardTo(self: *const Forwarder, addr: [4]u8, query: []const u8, response_buf: []u8) !usize {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(sock);

        // Set receive timeout
        const timeout_sec = self.timeout_ms / 1000;
        const timeout_usec = (self.timeout_ms % 1000) * 1000;
        const tv = posix.timeval{
            .sec = @intCast(timeout_sec),
            .usec = @intCast(timeout_usec),
        };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        const dest = posix.sockaddr.in{
            .port = std.mem.nativeToBig(u16, 53),
            .addr = @bitCast(addr),
        };

        _ = try posix.sendto(sock, query, 0, @ptrCast(&dest), @sizeOf(posix.sockaddr.in));

        const n = posix.recvfrom(sock, response_buf, 0, null, null) catch |err| {
            return switch (err) {
                error.WouldBlock => error.Timeout,
                else => err,
            };
        };

        return n;
    }

    pub const Timeout = error.Timeout;
};
