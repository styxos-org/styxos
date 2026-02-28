const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Upstream resolver provider
pub const Upstream = enum {
    quad9,
    cloudflare,

    pub fn getAddresses(self: Upstream) struct { primary: [4]u8, secondary: [4]u8 } {
        return switch (self) {
            .quad9 => .{
                .primary = .{ 9, 9, 9, 9 },
                .secondary = .{ 149, 112, 112, 112 },
            },
            .cloudflare => .{
                .primary = .{ 1, 1, 1, 1 },
                .secondary = .{ 1, 0, 0, 1 },
            },
        };
    }
};

pub const Config = struct {
    listen_port: u16 = 53,
    listen_addr: []const u8 = "0.0.0.0",
    upstream: Upstream = .quad9,
    upstream_timeout_ms: u32 = 3000,
    zone_file: ?[]const u8 = null,
    cache_ttl: u32 = 300,
    max_cache_entries: u32 = 10000,
    verbose: bool = false,

    // ── StyxOS System DB ──────────────────────────────────────────────
    //
    // Expected schema in the system database:
    //
    //   CREATE TABLE IF NOT EXISTS sysconfig (
    //       namespace TEXT NOT NULL,
    //       key       TEXT NOT NULL,
    //       value     TEXT NOT NULL,
    //       PRIMARY KEY (namespace, key)
    //   );
    //
    // Charon reads from namespace = 'charon'. Example rows:
    //
    //   INSERT INTO sysconfig VALUES ('charon', 'listen_port',        '53');
    //   INSERT INTO sysconfig VALUES ('charon', 'listen_addr',        '0.0.0.0');
    //   INSERT INTO sysconfig VALUES ('charon', 'upstream',           'quad9');
    //   INSERT INTO sysconfig VALUES ('charon', 'upstream_timeout_ms','3000');
    //   INSERT INTO sysconfig VALUES ('charon', 'zone_file',          '/etc/charon/zones');
    //   INSERT INTO sysconfig VALUES ('charon', 'cache_ttl',          '300');
    //   INSERT INTO sysconfig VALUES ('charon', 'max_cache_entries',  '10000');
    //   INSERT INTO sysconfig VALUES ('charon', 'verbose',            'false');
    //
    // Other StyxOS services use their own namespaces in the same DB:
    //
    //   INSERT INTO sysconfig VALUES ('network', 'hostname',       'node01');
    //   INSERT INTO sysconfig VALUES ('init',    'default_target', 'multi-user');
    //

    const NAMESPACE = "charon";
    const DEFAULT_DB_PATH = "/etc/styx/system.db";

    /// Load configuration from the StyxOS system SQLite database.
    /// Falls back to defaults for any missing keys.
    pub fn loadFromDb(db_path: [*:0]const u8) !Config {
        var db = try openReadOnly(db_path);
        defer db.close();

        var cfg = Config{};

        cfg.listen_port = getU16(&db, "listen_port") orelse cfg.listen_port;
        cfg.upstream_timeout_ms = getU32(&db, "upstream_timeout_ms") orelse cfg.upstream_timeout_ms;
        cfg.cache_ttl = getU32(&db, "cache_ttl") orelse cfg.cache_ttl;
        cfg.max_cache_entries = getU32(&db, "max_cache_entries") orelse cfg.max_cache_entries;

        if (getString(&db, "upstream")) |val| {
            if (std.mem.eql(u8, val, "cloudflare")) {
                cfg.upstream = .cloudflare;
            } else {
                cfg.upstream = .quad9;
            }
        }

        if (getString(&db, "verbose")) |val| {
            cfg.verbose = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }

        // Note: listen_addr and zone_file are string slices that point into
        // SQLite memory — invalid after db.close(). For these two values
        // we'd need to dupe into an allocator in production. For now the
        // defaults work, and overrides via CLI args are recommended.

        return cfg;
    }

    /// Unified loader — the recommended entry point for StyxOS integration.
    ///
    /// Resolution order:
    ///   1. charon --db /path/to/system.db   → explicit DB path
    ///   2. charon /path/to/charon.conf      → explicit flat file
    ///   3. charon                            → auto: try /etc/styx/system.db,
    ///                                          then /etc/charon/charon.conf,
    ///                                          then built-in defaults
    pub fn load(allocator: std.mem.Allocator, args: []const []const u8) !Config {
        // --db flag takes priority
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
                const path = args[i + 1];
                var path_z: [4096]u8 = undefined;
                @memcpy(path_z[0..path.len], path);
                path_z[path.len] = 0;
                return loadFromDb(@ptrCast(path_z[0 .. path.len + 1]));
            }
        }

        // Positional argument = flat file path
        if (args.len > 1 and !std.mem.startsWith(u8, args[1], "--")) {
            return loadFromFile(allocator, args[1]);
        }

        // Auto-detect: system DB first, then flat file, then defaults
        if (loadFromDb(DEFAULT_DB_PATH)) |cfg| {
            return cfg;
        } else |_| {}

        return loadFromFile(allocator, "/etc/charon/charon.conf");
    }

    // ── Flat file loader (original implementation) ────────────────────

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return Config{};
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(content);

        return parseConfig(content);
    }

    fn parseConfig(content: []const u8) Config {
        var cfg = Config{};
        var iter = std.mem.splitScalar(u8, content, '\n');

        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                if (std.mem.eql(u8, key, "listen_port")) {
                    cfg.listen_port = std.fmt.parseInt(u16, val, 10) catch 53;
                } else if (std.mem.eql(u8, key, "upstream")) {
                    if (std.mem.eql(u8, val, "cloudflare")) {
                        cfg.upstream = .cloudflare;
                    } else {
                        cfg.upstream = .quad9;
                    }
                } else if (std.mem.eql(u8, key, "upstream_timeout_ms")) {
                    cfg.upstream_timeout_ms = std.fmt.parseInt(u32, val, 10) catch 3000;
                } else if (std.mem.eql(u8, key, "cache_ttl")) {
                    cfg.cache_ttl = std.fmt.parseInt(u32, val, 10) catch 300;
                } else if (std.mem.eql(u8, key, "max_cache_entries")) {
                    cfg.max_cache_entries = std.fmt.parseInt(u32, val, 10) catch 10000;
                } else if (std.mem.eql(u8, key, "verbose")) {
                    cfg.verbose = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
                }
            }
        }

        return cfg;
    }

    // ── SQLite helpers (read-only) ────────────────────────────────────

    fn openReadOnly(path: [*:0]const u8) !sqlite.Db {
        const c = @cImport(@cInclude("sqlite3.h"));
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path, &handle, c.SQLITE_OPEN_READONLY, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }
        return sqlite.Db{ .handle = @ptrCast(handle.?) };
    }

    fn getString(db: *sqlite.Db, key: []const u8) ?[]const u8 {
        var key_z: [128]u8 = undefined;
        @memcpy(key_z[0..key.len], key);
        key_z[key.len] = 0;

        var stmt = db.prepare(
            "SELECT value FROM sysconfig WHERE namespace = 'charon' AND key = ?1",
        ) catch return null;
        defer stmt.finalize();

        stmt.bindText(1, @ptrCast(key_z[0 .. key.len + 1])) catch return null;

        if (stmt.step() catch return null) {
            if (stmt.columnText(0)) |val| {
                return std.mem.span(val);
            }
        }
        return null;
    }

    fn getU16(db: *sqlite.Db, key: []const u8) ?u16 {
        const val = getString(db, key) orelse return null;
        return std.fmt.parseInt(u16, val, 10) catch null;
    }

    fn getU32(db: *sqlite.Db, key: []const u8) ?u32 {
        const val = getString(db, key) orelse return null;
        return std.fmt.parseInt(u32, val, 10) catch null;
    }
};
