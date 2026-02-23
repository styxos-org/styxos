// zish query - SQL query builtin with multiple output formats
// License: GPL-3.0-or-later

const std = @import("std");
const db_mod = @import("db.zig");
const Db = db_mod.Db;

// Use the same C import as db.zig to avoid opaque type conflicts
const c = db_mod.c;

pub const OutputFormat = enum { table, json, csv };

/// Result of a raw SQL query: column names + rows of string values
pub const QueryResult = struct {
    columns: std.ArrayList([]const u8),
    rows: std.ArrayList(std.ArrayList([]const u8)),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.columns.items) |col| self.alloc.free(col);
        self.columns.deinit(self.alloc);
        for (self.rows.items) |*row| {
            for (row.items) |cell| self.alloc.free(cell);
            row.deinit(self.alloc);
        }
        self.rows.deinit(self.alloc);
    }
};

/// Execute an arbitrary SQL query and return column names + all rows as strings
pub fn executeQuery(db: *Db, alloc: std.mem.Allocator, sql: []const u8) !QueryResult {
    var result = QueryResult{
        .columns = .empty,
        .rows = .empty,
        .alloc = alloc,
    };
    errdefer result.deinit();

    const csql = try alloc.dupeZ(u8, sql);
    defer alloc.free(csql);

    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db.handle, csql.ptr, -1, &stmt, null);
    if (rc != c.SQLITE_OK) {
        const err_msg = c.sqlite3_errmsg(db.handle);
        if (err_msg) |msg|
            std.debug.print("query: SQL error: {s}\n", .{std.mem.sliceTo(msg, 0)});
        return db_mod.DbError.PrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Extract column names
    const col_count: usize = @intCast(c.sqlite3_column_count(stmt));
    for (0..col_count) |i| {
        const name_ptr = c.sqlite3_column_name(stmt, @intCast(i));
        const name = if (name_ptr) |p|
            try alloc.dupe(u8, std.mem.sliceTo(p, 0))
        else
            try alloc.dupe(u8, "?");
        try result.columns.append(alloc, name);
    }

    // Fetch rows
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var row: std.ArrayList([]const u8) = .empty;
        for (0..col_count) |i| {
            const val_ptr = c.sqlite3_column_text(stmt, @intCast(i));
            const val = if (val_ptr) |p|
                try alloc.dupe(u8, std.mem.sliceTo(p, 0))
            else
                try alloc.dupe(u8, "NULL");
            try row.append(alloc, val);
        }
        try result.rows.append(alloc, row);
    }

    return result;
}

// ── Output Formatters ────────────────────────────────────────────────

pub fn printTable(result: *const QueryResult) void {
    if (result.columns.items.len == 0) return;

    const alloc = result.alloc;
    const col_count = result.columns.items.len;

    // Calculate column widths
    var widths = alloc.alloc(usize, col_count) catch return;
    defer alloc.free(widths);

    for (result.columns.items, 0..) |col, i|
        widths[i] = col.len;

    for (result.rows.items) |row| {
        for (row.items, 0..) |cell, i| {
            if (i < col_count and cell.len > widths[i])
                widths[i] = cell.len;
        }
    }

    // Header
    for (result.columns.items, 0..) |col, i| {
        if (i > 0) std.debug.print("  ", .{});
        printPadded(col, widths[i]);
    }
    std.debug.print("\n", .{});

    // Separator
    for (widths, 0..) |w, i| {
        if (i > 0) std.debug.print("  ", .{});
        var j: usize = 0;
        while (j < w) : (j += 1) std.debug.print("-", .{});
    }
    std.debug.print("\n", .{});

    // Rows
    for (result.rows.items) |row| {
        for (row.items, 0..) |cell, i| {
            if (i >= col_count) break;
            if (i > 0) std.debug.print("  ", .{});
            printPadded(cell, widths[i]);
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("({d} rows)\n", .{result.rows.items.len});
}

fn printPadded(s: []const u8, width: usize) void {
    std.debug.print("{s}", .{s});
    var pad = s.len;
    while (pad < width) : (pad += 1) std.debug.print(" ", .{});
}

pub fn printJson(result: *const QueryResult) void {
    if (result.columns.items.len == 0) {
        std.debug.print("[]\n", .{});
        return;
    }

    std.debug.print("[\n", .{});
    for (result.rows.items, 0..) |row, ri| {
        std.debug.print("  {{", .{});
        for (row.items, 0..) |cell, i| {
            if (i >= result.columns.items.len) break;
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("\"{s}\": ", .{result.columns.items[i]});
            // Try to detect numbers
            if (isNumeric(cell)) {
                std.debug.print("{s}", .{cell});
            } else if (std.mem.eql(u8, cell, "NULL")) {
                std.debug.print("null", .{});
            } else {
                printJsonString(cell);
            }
        }
        if (ri + 1 < result.rows.items.len) {
            std.debug.print("}},\n", .{});
        } else {
            std.debug.print("}}\n", .{});
        }
    }
    std.debug.print("]\n", .{});
}

fn printJsonString(s: []const u8) void {
    std.debug.print("\"", .{});
    for (s) |ch| {
        switch (ch) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            else => std.debug.print("{c}", .{ch}),
        }
    }
    std.debug.print("\"", .{});
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_dot = false;
    for (s, 0..) |ch, i| {
        if (ch == '-' and i == 0) continue;
        if (ch == '.' and !has_dot) {
            has_dot = true;
            continue;
        }
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

pub fn printCsv(result: *const QueryResult) void {
    if (result.columns.items.len == 0) return;

    // Header
    for (result.columns.items, 0..) |col, i| {
        if (i > 0) std.debug.print(",", .{});
        printCsvField(col);
    }
    std.debug.print("\n", .{});

    // Rows
    for (result.rows.items) |row| {
        for (row.items, 0..) |cell, i| {
            if (i >= result.columns.items.len) break;
            if (i > 0) std.debug.print(",", .{});
            printCsvField(cell);
        }
        std.debug.print("\n", .{});
    }
}

fn printCsvField(s: []const u8) void {
    var needs_quoting = false;
    for (s) |ch| {
        if (ch == ',' or ch == '"' or ch == '\n' or ch == '\r') {
            needs_quoting = true;
            break;
        }
    }
    if (!needs_quoting) {
        std.debug.print("{s}", .{s});
        return;
    }
    std.debug.print("\"", .{});
    for (s) |ch| {
        if (ch == '"') {
            std.debug.print("\"\"", .{});
        } else {
            std.debug.print("{c}", .{ch});
        }
    }
    std.debug.print("\"", .{});
}

// ── Builtin Interface ────────────────────────────────────────────────

var query_db: *Db = undefined;
var query_alloc: std.mem.Allocator = undefined;
var query_db_active: bool = false;

pub fn init(alloc: std.mem.Allocator, db: *Db, db_active: bool) void {
    query_alloc = alloc;
    query_db = db;
    query_db_active = db_active;
}

/// Builtin handler for "query" command
/// Usage: query [--json|--csv] "SQL statement"
pub fn builtinQuery(args: []const []const u8) bool {
    if (!query_db_active) {
        std.debug.print("query: database not available\n", .{});
        return true;
    }

    if (args.len < 2) {
        printUsage();
        return true;
    }

    var format: OutputFormat = .table;
    var sql_start: usize = 1;

    // Parse format flags
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            format = .json;
            sql_start = i + 1;
        } else if (std.mem.eql(u8, arg, "--csv") or std.mem.eql(u8, arg, "-c")) {
            format = .csv;
            sql_start = i + 1;
        } else if (std.mem.eql(u8, arg, "--table") or std.mem.eql(u8, arg, "-t")) {
            format = .table;
            sql_start = i + 1;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return true;
        } else {
            break;
        }
    }

    if (sql_start >= args.len) {
        printUsage();
        return true;
    }

    // Join remaining args as SQL (allows unquoted simple queries)
    var sql_buf: [4096]u8 = undefined;
    var sql_len: usize = 0;
    for (args[sql_start..], 0..) |arg, i| {
        if (i > 0 and sql_len < sql_buf.len) {
            sql_buf[sql_len] = ' ';
            sql_len += 1;
        }
        const copy_len = @min(arg.len, sql_buf.len - sql_len);
        @memcpy(sql_buf[sql_len .. sql_len + copy_len], arg[0..copy_len]);
        sql_len += copy_len;
    }
    const sql = sql_buf[0..sql_len];

    var result = executeQuery(query_db, query_alloc, sql) catch return true;
    defer result.deinit();

    switch (format) {
        .table => printTable(&result),
        .json => printJson(&result),
        .csv => printCsv(&result),
    }

    return true;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: query [OPTIONS] SQL
        \\
        \\Execute SQL against the zish database and display results.
        \\
        \\Options:
        \\  --table, -t   Table format (default)
        \\  --json,  -j   JSON format
        \\  --csv,   -c   CSV format
        \\
        \\Examples:
        \\  query SELECT * FROM history ORDER BY id DESC LIMIT 10
        \\  query --json SELECT command, exit_code FROM history WHERE cwd LIKE '%/myproject%'
        \\  query --csv SELECT key, value FROM environment
        \\  query "SELECT name, command FROM aliases"
        \\
    , .{});
}
