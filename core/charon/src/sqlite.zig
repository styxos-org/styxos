const c = @cImport({
    @cInclude("sqlite3.h");
});
const std = @import("std");

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn openInMemory() !Db {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(":memory:", &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        return Db{ .handle = db.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn exec(self: *Db, sql: [*:0]const u8) !void {
        const rc = c.sqlite3_exec(self.handle, sql, null, null, null);
        if (rc != c.SQLITE_OK) {
            return error.SqliteExecFailed;
        }
    }

    pub fn prepare(self: *Db, sql: [*:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        return Stmt{ .handle = stmt.? };
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn bindText(self: *Stmt, col: c_int, text: [*:0]const u8) !void {
        const rc = c.sqlite3_bind_text(self.handle, col, text, -1, c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt(self: *Stmt, col: c_int, val: c_int) !void {
        const rc = c.sqlite3_bind_int(self.handle, col, val);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt64(self: *Stmt, col: c_int, val: i64) !void {
        const rc = c.sqlite3_bind_int64(self.handle, col, val);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn step(self: *Stmt) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.SqliteStepFailed;
    }

    pub fn columnText(self: *Stmt, col: c_int) ?[*:0]const u8 {
        return @ptrCast(c.sqlite3_column_text(self.handle, col));
    }

    pub fn columnInt(self: *Stmt, col: c_int) c_int {
        return c.sqlite3_column_int(self.handle, col);
    }

    pub fn columnInt64(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, col);
    }

    pub fn reset(self: *Stmt) !void {
        const rc = c.sqlite3_reset(self.handle);
        if (rc != c.SQLITE_OK) return error.SqliteResetFailed;
    }

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};
