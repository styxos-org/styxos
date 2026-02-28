const std = @import("std");
const posix = std.posix;

const dns = @import("dns.zig");
const zone = @import("zone.zig");
const config_mod = @import("config.zig");
const forwarder_mod = @import("forwarder.zig");
const control_mod = @import("control.zig");

const log = std.log.scoped(.charon);

const Config = config_mod.Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cfg = Config.load(allocator, args) catch Config{};

    log.info("charon DNS resolver starting", .{});
    log.info("upstream: {s}", .{if (cfg.upstream == .quad9) "quad9 (9.9.9.9)" else "cloudflare (1.1.1.1)"});
    log.info("listen: {s}:{d}", .{ cfg.listen_addr, cfg.listen_port });

    // Initialize zone database (in-memory SQLite)
    var zonedb = try zone.ZoneDb.init();
    defer zonedb.deinit();

    // Load zone file if configured
    if (cfg.zone_file) |zf| {
        const count = zonedb.loadZoneFile(allocator, zf) catch |err| {
            log.err("failed to load zone file {s}: {}", .{ zf, err });
            return;
        };
        log.info("loaded {d} records from zone file {s}", .{ count, zf });
    }

    // Initialize forwarder
    const fwd = forwarder_mod.Forwarder.init(cfg.upstream, cfg.upstream_timeout_ms);

    // Start control socket
    var ctl = control_mod.ControlSocket.init(&zonedb, "/run/charon.sock");
    ctl.start() catch |err| {
        log.warn("control socket failed: {}, continuing without", .{err});
    };
    defer ctl.deinit();

    // Create UDP socket
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(sock);

    // Allow address reuse
    const one: c_int = 1;
    try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));

    const bind_addr = posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, cfg.listen_port),
        .addr = 0, // INADDR_ANY
    };
    posix.bind(sock, @ptrCast(&bind_addr), @sizeOf(posix.sockaddr.in)) catch |err| {
        switch (err) {
            error.AccessDenied => {
                log.err("permission denied binding to port {d}", .{cfg.listen_port});
                if (cfg.listen_port < 1024) {
                    log.err("ports below 1024 require root privileges or CAP_NET_BIND_SERVICE", .{});
                    log.err("options: run as root, use setcap, or set listen_port > 1024", .{});
                }
            },
            error.AddressInUse => {
                log.err("port {d} is already in use — another DNS server running?", .{cfg.listen_port});
            },
            else => {
                log.err("failed to bind to {s}:{d}: {}", .{ cfg.listen_addr, cfg.listen_port, err });
            },
        }
        return;
    };

    log.info("listening for DNS queries on port {d}", .{cfg.listen_port});

    // Main event loop
    var recv_buf: [512]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;

    while (true) {
        // Poll control socket (non-blocking)
        ctl.poll() catch {};

        // Periodic cache eviction (simplified: every request)
        zonedb.evictExpired() catch {};

        var src_addr: posix.sockaddr = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const n = posix.recvfrom(sock, &recv_buf, 0, &src_addr, &addr_len) catch |err| {
            log.err("recvfrom error: {}", .{err});
            continue;
        };

        if (n < 12) continue; // Too small for DNS header

        const query = recv_buf[0..n];
        const resp_len = handleQuery(query, &resp_buf, &zonedb, &fwd, cfg.verbose) catch |err| {
            log.err("query handling error: {}", .{err});
            // Send SERVFAIL
            const servfail_len = makeServfail(query, &resp_buf) catch continue;
            _ = posix.sendto(sock, resp_buf[0..servfail_len], 0, &src_addr, addr_len) catch {};
            continue;
        };

        _ = posix.sendto(sock, resp_buf[0..resp_len], 0, &src_addr, addr_len) catch |err| {
            log.err("sendto error: {}", .{err});
        };
    }
}

fn handleQuery(
    query: []const u8,
    resp_buf: []u8,
    zonedb: *zone.ZoneDb,
    fwd: *const forwarder_mod.Forwarder,
    verbose: bool,
) !usize {
    const header = try dns.Header.parse(query);
    if (!header.isQuery()) return error.NotAQuery;
    if (header.qd_count == 0) return error.NoQuestion;

    // Parse the question section
    const parsed = try dns.Question.parse(query, 12);
    const question = parsed.question;
    const qname = question.getName();
    const qtype: dns.RecordType = @enumFromInt(question.qtype);

    if (verbose) {
        log.info("query: {s} {s}", .{ qname, qtype.toString() });
    }

    // 1. Check local zones first
    var local_results: [32]zone.ZoneRecord = undefined;
    const local_count = try zonedb.lookupLocal(qname, qtype, &local_results);

    if (local_count > 0) {
        if (verbose) log.info("  -> local zone hit ({d} records)", .{local_count});
        return buildLocalResponse(header, &question, local_results[0..local_count], resp_buf);
    }

    // 2. Check forwarded-record cache
    var cache_results: [32]zone.ZoneRecord = undefined;
    const cache_count = try zonedb.lookupCache(qname, qtype, &cache_results);

    if (cache_count > 0) {
        if (verbose) log.info("  -> cache hit ({d} records)", .{cache_count});
        return buildLocalResponse(header, &question, cache_results[0..cache_count], resp_buf);
    }

    // 3. Forward to upstream
    if (verbose) log.info("  -> forwarding to upstream", .{});
    const upstream_len = fwd.forward(query, resp_buf) catch |err| {
        log.err("  -> upstream failed: {}", .{err});
        return error.UpstreamFailed;
    };

    // Cache the upstream response (best-effort, don't fail on cache errors)
    cacheUpstreamResponse(resp_buf[0..upstream_len], zonedb, qname, qtype) catch {};

    return upstream_len;
}

fn buildLocalResponse(
    header: dns.Header,
    question: *const dns.Question,
    records: []const zone.ZoneRecord,
    buf: []u8,
) !usize {
    const an_count: u16 = @intCast(records.len);
    const resp_header = header.makeResponse(.no_error, an_count);

    var pos = try resp_header.serialize(buf);

    // Write question section
    pos = try question.serialize(buf, pos);

    // Write answer section
    for (records) |rec| {
        const rdata_text = rec.rdata[0..rec.rdata_len];
        const rtype = rec.rtype;

        switch (rtype) {
            .A => {
                const ipv4 = dns.parseIPv4(rdata_text) catch continue;
                pos = try dns.serializeAnswer(buf, pos, rec.name[0..rec.name_len], .A, rec.ttl, &ipv4);
            },
            .AAAA => {
                const ipv6 = dns.parseIPv6(rdata_text) catch continue;
                pos = try dns.serializeAnswer(buf, pos, rec.name[0..rec.name_len], .AAAA, rec.ttl, &ipv6);
            },
            .CNAME => {
                var cname_buf: [256]u8 = undefined;
                const cname_len = dns.encodeDomainName(&cname_buf, rdata_text) catch continue;
                pos = try dns.serializeAnswer(buf, pos, rec.name[0..rec.name_len], .CNAME, rec.ttl, cname_buf[0..cname_len]);
            },
            .TXT => {
                // TXT record: length-prefixed string
                var txt_buf: [256]u8 = undefined;
                if (rdata_text.len > 255) continue;
                txt_buf[0] = @intCast(rdata_text.len);
                @memcpy(txt_buf[1 .. 1 + rdata_text.len], rdata_text);
                pos = try dns.serializeAnswer(buf, pos, rec.name[0..rec.name_len], .TXT, rec.ttl, txt_buf[0 .. 1 + rdata_text.len]);
            },
            else => continue,
        }
    }

    return pos;
}

fn cacheUpstreamResponse(
    response: []const u8,
    zonedb: *zone.ZoneDb,
    qname: []const u8,
    qtype: dns.RecordType,
) !void {
    // Simple approach: cache the text representation
    // Parse answer count from the response header
    if (response.len < 12) return;
    const an_count = dns.readU16(response[6..8]);
    if (an_count == 0) return;

    // For simplicity, cache the query result as a placeholder
    // A full implementation would parse each RR from the response
    _ = zonedb;
    _ = qname;
    _ = qtype;
    // TODO: Parse individual RRs from upstream response and cache them
    // This is left as an improvement point - for now the full upstream
    // response is returned directly and not individually cached.
}

fn makeServfail(query: []const u8, buf: []u8) !usize {
    if (query.len < 12) return error.BufferTooSmall;

    const header = try dns.Header.parse(query);
    const resp = header.makeResponse(.server_failure, 0);
    var pos = try resp.serialize(buf);

    // Copy question section if present
    if (header.qd_count > 0) {
        const parsed = dns.Question.parse(query, 12) catch return pos;
        pos = try parsed.question.serialize(buf, pos);
    }

    return pos;
}
