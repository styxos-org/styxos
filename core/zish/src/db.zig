// zish database layer - SQLite backed persistent shell state
// License: GPL-3.0-or-later

const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DbError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
};

pub const HistoryEntry = struct {
    id: i64,
    command: []const u8,
    cwd: []const u8,
    timestamp: i64,
    exit_code: i32,
};

pub const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const AliasEntry = struct {
    name: []const u8,
    command: []const u8,
};

pub const Db = struct {
    handle: *c.sqlite3, // pub for query module access
    alloc: std.mem.Allocator,

    const schema =
        \\CREATE TABLE IF NOT EXISTS history (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    command TEXT NOT NULL,
        \\    cwd TEXT NOT NULL DEFAULT '',
        \\    timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
        \\    exit_code INTEGER NOT NULL DEFAULT 0
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS environment (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS aliases (
        \\    name TEXT PRIMARY KEY,
        \\    command TEXT NOT NULL
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS settings (
        \\    key TEXT PRIMARY KEY,
        \\    value TEXT NOT NULL
        \\);
        \\
        \\CREATE INDEX IF NOT EXISTS idx_history_ts ON history(timestamp DESC);
        \\CREATE INDEX IF NOT EXISTS idx_history_cmd ON history(command);
        \\CREATE INDEX IF NOT EXISTS idx_history_cwd ON history(cwd);
    ;

    pub fn open(alloc: std.mem.Allocator, path: []const u8) !Db {
        const cpath = try alloc.dupeZ(u8, path);
        defer alloc.free(cpath);

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(cpath.ptr, &handle);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }

        var db = Db{ .handle = handle.?, .alloc = alloc };
        try db.exec("PRAGMA journal_mode=WAL;");
        try db.exec("PRAGMA foreign_keys=ON;");
        try db.exec(schema);
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn exec(self: *Db, sql: []const u8) !void {
        const csql = self.alloc.dupeZ(u8, sql) catch return DbError.ExecFailed;
        defer self.alloc.free(csql);

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, csql.ptr, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.debug.print("zish: db error: {s}\n", .{msg});
                c.sqlite3_free(msg);
            }
            return DbError.ExecFailed;
        }
    }

    // ── History ──────────────────────────────────────────────────────

    pub fn addHistory(self: *Db, command: []const u8, cwd: []const u8, exit_code: i32) !void {
        const sql = "INSERT INTO history (command, cwd, exit_code) VALUES (?1, ?2, ?3);";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ccmd = try self.alloc.dupeZ(u8, command);
        defer self.alloc.free(ccmd);
        const ccwd = try self.alloc.dupeZ(u8, cwd);
        defer self.alloc.free(ccwd);

        if (c.sqlite3_bind_text(stmt, 1, ccmd.ptr, @intCast(ccmd.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, ccwd.ptr, @intCast(ccwd.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_int(stmt, 3, exit_code) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE)
            return DbError.StepFailed;
    }

    pub fn getHistory(self: *Db, limit: u32) !std.ArrayList(HistoryEntry) {
        var results: std.ArrayList(HistoryEntry) = .empty;
        errdefer results.deinit(self.alloc);

        const sql = "SELECT id, command, cwd, timestamp, exit_code FROM history ORDER BY id DESC LIMIT ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int(stmt, 1, @intCast(limit)) != c.SQLITE_OK)
            return DbError.BindFailed;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const cmd_ptr = c.sqlite3_column_text(stmt, 1);
            const cwd_ptr = c.sqlite3_column_text(stmt, 2);
            const cmd = if (cmd_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            const cwd = if (cwd_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            try results.append(self.alloc, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .command = cmd,
                .cwd = cwd,
                .timestamp = c.sqlite3_column_int64(stmt, 3),
                .exit_code = c.sqlite3_column_int(stmt, 4),
            });
        }

        std.mem.reverse(HistoryEntry, results.items);
        return results;
    }

    pub fn searchHistory(self: *Db, prefix: []const u8, limit: u32) !std.ArrayList(HistoryEntry) {
        var results: std.ArrayList(HistoryEntry) = .empty;
        errdefer results.deinit(self.alloc);

        const sql = "SELECT id, command, cwd, timestamp, exit_code FROM history WHERE command LIKE ?1 ORDER BY id DESC LIMIT ?2;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const pattern_str = try std.fmt.allocPrint(self.alloc, "{s}%", .{prefix});
        defer self.alloc.free(pattern_str);
        const pattern = try self.alloc.dupeZ(u8, pattern_str);
        defer self.alloc.free(pattern);

        if (c.sqlite3_bind_text(stmt, 1, pattern.ptr, @intCast(pattern.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_int(stmt, 2, @intCast(limit)) != c.SQLITE_OK)
            return DbError.BindFailed;

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const cmd_ptr = c.sqlite3_column_text(stmt, 1);
            const cwd_ptr = c.sqlite3_column_text(stmt, 2);
            const cmd = if (cmd_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            const cwd = if (cwd_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            try results.append(self.alloc, .{
                .id = c.sqlite3_column_int64(stmt, 0),
                .command = cmd,
                .cwd = cwd,
                .timestamp = c.sqlite3_column_int64(stmt, 3),
                .exit_code = c.sqlite3_column_int(stmt, 4),
            });
        }

        return results;
    }

    pub fn historyCount(self: *Db) !i64 {
        const sql = "SELECT COUNT(*) FROM history;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW)
            return c.sqlite3_column_int64(stmt, 0);
        return 0;
    }

    // ── Environment ──────────────────────────────────────────────────

    pub fn setEnv(self: *Db, key: []const u8, value: []const u8) !void {
        const sql = "INSERT OR REPLACE INTO environment (key, value) VALUES (?1, ?2);";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ckey = try self.alloc.dupeZ(u8, key);
        defer self.alloc.free(ckey);
        const cval = try self.alloc.dupeZ(u8, value);
        defer self.alloc.free(cval);

        if (c.sqlite3_bind_text(stmt, 1, ckey.ptr, @intCast(ckey.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, cval.ptr, @intCast(cval.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }

    pub fn removeEnv(self: *Db, key: []const u8) !void {
        const sql = "DELETE FROM environment WHERE key = ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ckey = try self.alloc.dupeZ(u8, key);
        defer self.alloc.free(ckey);
        if (c.sqlite3_bind_text(stmt, 1, ckey.ptr, @intCast(ckey.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }

    pub fn getAllEnv(self: *Db) !std.ArrayList(EnvEntry) {
        var results: std.ArrayList(EnvEntry) = .empty;
        errdefer results.deinit(self.alloc);

        const sql = "SELECT key, value FROM environment ORDER BY key;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const key_ptr = c.sqlite3_column_text(stmt, 0);
            const val_ptr = c.sqlite3_column_text(stmt, 1);
            const key = if (key_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            const val = if (val_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            try results.append(self.alloc, .{ .key = key, .value = val });
        }
        return results;
    }

    // ── Aliases ──────────────────────────────────────────────────────

    pub fn setAlias(self: *Db, name: []const u8, command: []const u8) !void {
        const sql = "INSERT OR REPLACE INTO aliases (name, command) VALUES (?1, ?2);";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const cname = try self.alloc.dupeZ(u8, name);
        defer self.alloc.free(cname);
        const ccmd = try self.alloc.dupeZ(u8, command);
        defer self.alloc.free(ccmd);

        if (c.sqlite3_bind_text(stmt, 1, cname.ptr, @intCast(cname.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, ccmd.ptr, @intCast(ccmd.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }

    pub fn removeAlias(self: *Db, name: []const u8) !void {
        const sql = "DELETE FROM aliases WHERE name = ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const cname = try self.alloc.dupeZ(u8, name);
        defer self.alloc.free(cname);
        if (c.sqlite3_bind_text(stmt, 1, cname.ptr, @intCast(cname.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }

    pub fn getAllAliases(self: *Db) !std.ArrayList(AliasEntry) {
        var results: std.ArrayList(AliasEntry) = .empty;
        errdefer results.deinit(self.alloc);

        const sql = "SELECT name, command FROM aliases ORDER BY name;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name_ptr = c.sqlite3_column_text(stmt, 0);
            const cmd_ptr = c.sqlite3_column_text(stmt, 1);
            const name = if (name_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            const cmd = if (cmd_ptr) |p| try self.alloc.dupe(u8, std.mem.sliceTo(p, 0)) else try self.alloc.dupe(u8, "");
            try results.append(self.alloc, .{ .name = name, .command = cmd });
        }
        return results;
    }

    pub fn getAlias(self: *Db, name: []const u8) !?[]const u8 {
        const sql = "SELECT command FROM aliases WHERE name = ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const cname = try self.alloc.dupeZ(u8, name);
        defer self.alloc.free(cname);
        if (c.sqlite3_bind_text(stmt, 1, cname.ptr, @intCast(cname.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const cmd_ptr = c.sqlite3_column_text(stmt, 0);
            if (cmd_ptr) |p|
                return try self.alloc.dupe(u8, std.mem.sliceTo(p, 0));
        }
        return null;
    }

    // ── Settings ─────────────────────────────────────────────────────

    pub fn setSetting(self: *Db, key: []const u8, value: []const u8) !void {
        const sql = "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2);";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ckey = try self.alloc.dupeZ(u8, key);
        defer self.alloc.free(ckey);
        const cval = try self.alloc.dupeZ(u8, value);
        defer self.alloc.free(cval);

        if (c.sqlite3_bind_text(stmt, 1, ckey.ptr, @intCast(ckey.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_bind_text(stmt, 2, cval.ptr, @intCast(cval.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }

    pub fn getSetting(self: *Db, key: []const u8) !?[]const u8 {
        const sql = "SELECT value FROM settings WHERE key = ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ckey = try self.alloc.dupeZ(u8, key);
        defer self.alloc.free(ckey);
        if (c.sqlite3_bind_text(stmt, 1, ckey.ptr, @intCast(ckey.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const val_ptr = c.sqlite3_column_text(stmt, 0);
            if (val_ptr) |p|
                return try self.alloc.dupe(u8, std.mem.sliceTo(p, 0));
        }
        return null;
    }

    pub fn removeSetting(self: *Db, key: []const u8) !void {
        const sql = "DELETE FROM settings WHERE key = ?1;";
        const csql = try self.alloc.dupeZ(u8, sql);
        defer self.alloc.free(csql);

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, csql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return DbError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const ckey = try self.alloc.dupeZ(u8, key);
        defer self.alloc.free(ckey);
        if (c.sqlite3_bind_text(stmt, 1, ckey.ptr, @intCast(ckey.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return DbError.BindFailed;
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return DbError.StepFailed;
    }
};
