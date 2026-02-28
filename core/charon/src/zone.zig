const std = @import("std");
const sqlite = @import("sqlite.zig");
const dns = @import("dns.zig");

pub const ZoneRecord = struct {
    name: [256]u8,
    name_len: usize,
    rtype: dns.RecordType,
    rdata: [512]u8,
    rdata_len: usize,
    ttl: u32,

    pub fn getName(self: *const ZoneRecord) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getRdata(self: *const ZoneRecord) []const u8 {
        return self.rdata[0..self.rdata_len];
    }
};

pub const ZoneDb = struct {
    db: sqlite.Db,

    const SCHEMA =
        \\CREATE TABLE IF NOT EXISTS local_zones (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL COLLATE NOCASE,
        \\    rtype TEXT NOT NULL,
        \\    rdata TEXT NOT NULL,
        \\    ttl INTEGER NOT NULL DEFAULT 0
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_zones_name_type ON local_zones(name, rtype);
        \\
        \\CREATE TABLE IF NOT EXISTS cache (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL COLLATE NOCASE,
        \\    rtype TEXT NOT NULL,
        \\    rdata TEXT NOT NULL,
        \\    ttl INTEGER NOT NULL,
        \\    inserted_at INTEGER NOT NULL
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_cache_name_type ON cache(name, rtype);
    ;

    pub fn init() !ZoneDb {
        var db = try sqlite.Db.openInMemory();
        try db.exec(SCHEMA);
        return ZoneDb{ .db = db };
    }

    pub fn deinit(self: *ZoneDb) void {
        self.db.close();
    }

    // ── Local Zone Management ─────────────────────────────────────────

    pub fn addRecord(self: *ZoneDb, name: []const u8, rtype: dns.RecordType, rdata: []const u8, ttl: u32) !void {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var rtype_buf: [8]u8 = undefined;
        const rtype_str = rtype.toString();
        @memcpy(rtype_buf[0..rtype_str.len], rtype_str);
        rtype_buf[rtype_str.len] = 0;

        var rdata_buf: [513]u8 = undefined;
        @memcpy(rdata_buf[0..rdata.len], rdata);
        rdata_buf[rdata.len] = 0;

        var stmt = try self.db.prepare(
            "INSERT INTO local_zones (name, rtype, rdata, ttl) VALUES (?1, ?2, ?3, ?4)",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        try stmt.bindText(2, @ptrCast(rtype_buf[0 .. rtype_str.len + 1]));
        try stmt.bindText(3, @ptrCast(rdata_buf[0 .. rdata.len + 1]));
        try stmt.bindInt(4, @intCast(ttl));
        _ = try stmt.step();
    }

    pub fn lookupLocal(self: *ZoneDb, name: []const u8, rtype: dns.RecordType, results: []ZoneRecord) !usize {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var rtype_buf: [8]u8 = undefined;
        const rtype_str = rtype.toString();
        @memcpy(rtype_buf[0..rtype_str.len], rtype_str);
        rtype_buf[rtype_str.len] = 0;

        var stmt = try self.db.prepare(
            "SELECT name, rtype, rdata, ttl FROM local_zones WHERE name = ?1 AND rtype = ?2",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        try stmt.bindText(2, @ptrCast(rtype_buf[0 .. rtype_str.len + 1]));

        var count: usize = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;

            var rec = &results[count];
            rec.rtype = rtype;
            rec.ttl = 0; // Local zones: no TTL/cache

            if (stmt.columnText(0)) |n| {
                const n_slice = std.mem.span(n);
                @memcpy(rec.name[0..n_slice.len], n_slice);
                rec.name_len = n_slice.len;
            }
            if (stmt.columnText(2)) |r| {
                const r_slice = std.mem.span(r);
                @memcpy(rec.rdata[0..r_slice.len], r_slice);
                rec.rdata_len = r_slice.len;
            }
            rec.ttl = @intCast(stmt.columnInt(3));
            count += 1;
        }

        return count;
    }

    /// Check if a name exists in any local zone (any record type)
    pub fn hasLocalZone(self: *ZoneDb, name: []const u8) !bool {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var stmt = try self.db.prepare(
            "SELECT 1 FROM local_zones WHERE name = ?1 LIMIT 1",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        return try stmt.step();
    }

    pub fn deleteLocalRecord(self: *ZoneDb, name: []const u8, rtype: dns.RecordType) !void {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var rtype_buf: [8]u8 = undefined;
        const rtype_str = rtype.toString();
        @memcpy(rtype_buf[0..rtype_str.len], rtype_str);
        rtype_buf[rtype_str.len] = 0;

        var stmt = try self.db.prepare(
            "DELETE FROM local_zones WHERE name = ?1 AND rtype = ?2",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        try stmt.bindText(2, @ptrCast(rtype_buf[0 .. rtype_str.len + 1]));
        _ = try stmt.step();
    }

    // ── Cache (Forwarded Records) ─────────────────────────────────────

    pub fn cacheRecord(self: *ZoneDb, name: []const u8, rtype: dns.RecordType, rdata: []const u8, ttl: u32) !void {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var rtype_buf: [8]u8 = undefined;
        const rtype_str = rtype.toString();
        @memcpy(rtype_buf[0..rtype_str.len], rtype_str);
        rtype_buf[rtype_str.len] = 0;

        var rdata_buf: [513]u8 = undefined;
        @memcpy(rdata_buf[0..rdata.len], rdata);
        rdata_buf[rdata.len] = 0;

        const now = std.time.timestamp();

        var stmt = try self.db.prepare(
            "INSERT INTO cache (name, rtype, rdata, ttl, inserted_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        try stmt.bindText(2, @ptrCast(rtype_buf[0 .. rtype_str.len + 1]));
        try stmt.bindText(3, @ptrCast(rdata_buf[0 .. rdata.len + 1]));
        try stmt.bindInt(4, @intCast(ttl));
        try stmt.bindInt64(5, now);
        _ = try stmt.step();
    }

    pub fn lookupCache(self: *ZoneDb, name: []const u8, rtype: dns.RecordType, results: []ZoneRecord) !usize {
        var name_buf: [257]u8 = undefined;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        var rtype_buf: [8]u8 = undefined;
        const rtype_str = rtype.toString();
        @memcpy(rtype_buf[0..rtype_str.len], rtype_str);
        rtype_buf[rtype_str.len] = 0;

        const now = std.time.timestamp();

        var stmt = try self.db.prepare(
            "SELECT name, rtype, rdata, ttl, inserted_at FROM cache WHERE name = ?1 AND rtype = ?2",
        );
        defer stmt.finalize();

        try stmt.bindText(1, @ptrCast(name_buf[0 .. name.len + 1]));
        try stmt.bindText(2, @ptrCast(rtype_buf[0 .. rtype_str.len + 1]));

        var count: usize = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;

            const ttl_val = stmt.columnInt(3);
            const inserted = stmt.columnInt64(4);
            const age = now - inserted;

            // Check if cache entry has expired
            if (age > @as(i64, ttl_val)) continue;

            var rec = &results[count];
            rec.rtype = rtype;
            rec.ttl = @intCast(@max(0, @as(i64, ttl_val) - age));

            if (stmt.columnText(0)) |n| {
                const n_slice = std.mem.span(n);
                @memcpy(rec.name[0..n_slice.len], n_slice);
                rec.name_len = n_slice.len;
            }
            if (stmt.columnText(2)) |r| {
                const r_slice = std.mem.span(r);
                @memcpy(rec.rdata[0..r_slice.len], r_slice);
                rec.rdata_len = r_slice.len;
            }
            count += 1;
        }

        return count;
    }

    /// Flush the entire forwarded-records cache
    pub fn flushCache(self: *ZoneDb) !void {
        try self.db.exec("DELETE FROM cache");
    }

    /// Remove expired cache entries
    pub fn evictExpired(self: *ZoneDb) !void {
        const now = std.time.timestamp();
        var stmt = try self.db.prepare(
            "DELETE FROM cache WHERE (inserted_at + ttl) < ?1",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, now);
        _ = try stmt.step();
    }

    /// Get cache entry count
    pub fn cacheCount(self: *ZoneDb) !u32 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM cache");
        defer stmt.finalize();
        if (try stmt.step()) {
            return @intCast(stmt.columnInt(0));
        }
        return 0;
    }

    // ── Zone File Loading ─────────────────────────────────────────────

    /// Load zone records from a simple zone file format:
    /// name  TYPE  value  [ttl]
    /// e.g.: myhost.local  A  192.168.1.10  3600
    pub fn loadZoneFile(self: *ZoneDb, allocator: std.mem.Allocator, path: []const u8) !usize {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;

            // Parse: name  TYPE  value  [ttl]
            var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
            const name = parts.next() orelse continue;
            const rtype_str = parts.next() orelse continue;
            const rdata = parts.next() orelse continue;
            const ttl_str = parts.next();

            const rtype = dns.RecordType.fromString(rtype_str) orelse continue;
            const ttl: u32 = if (ttl_str) |ts| std.fmt.parseInt(u32, ts, 10) catch 0 else 0;

            self.addRecord(name, rtype, rdata, ttl) catch continue;
            count += 1;
        }

        return count;
    }
};
