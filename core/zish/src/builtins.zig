// zish builtins - shell built-in commands
// License: GPL-3.0-or-later

const std = @import("std");
const db_mod = @import("db.zig");
const query_mod = @import("query.zig");
const Db = db_mod.Db;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
});

var shell_db: *Db = undefined;
var db_initialized: bool = false;
var alloc: std.mem.Allocator = undefined;
var db_path: []const u8 = "";

pub fn init(allocator: std.mem.Allocator, db: *Db, db_active: bool, path: []const u8) void {
    alloc = allocator;
    shell_db = db;
    db_initialized = db_active;
    db_path = path;
    query_mod.init(allocator, db, db_active);
}

pub const BuiltinFn = *const fn (args: []const []const u8) bool;

const BuiltinEntry = struct { name: []const u8, func: BuiltinFn };

const builtin_table = [_]BuiltinEntry{
    .{ .name = "cd", .func = builtinCd },
    .{ .name = "pwd", .func = builtinPwd },
    .{ .name = "exit", .func = builtinExit },
    .{ .name = "export", .func = builtinExport },
    .{ .name = "unset", .func = builtinUnset },
    .{ .name = "history", .func = builtinHistory },
    .{ .name = "alias", .func = builtinAlias },
    .{ .name = "unalias", .func = builtinUnalias },
    .{ .name = "query", .func = query_mod.builtinQuery },
    .{ .name = "config", .func = builtinConfig },
    .{ .name = "dbinfo", .func = builtinDbInfo },
    .{ .name = "help", .func = builtinHelp },
};

pub fn findBuiltin(name: []const u8) ?BuiltinFn {
    for (builtin_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

/// Return the builtin table for use by tab completion
pub fn getBuiltinNames() []const BuiltinEntry {
    return &builtin_table;
}

pub fn lookupAlias(name: []const u8) ?[]const u8 {
    if (!db_initialized) return null;
    return shell_db.getAlias(name) catch null;
}

// ── Config helpers ───────────────────────────────────────────────────

/// Get a config value from settings table, returning default if not found
pub fn getConfig(key: []const u8, default: []const u8) []const u8 {
    if (!db_initialized) return default;
    const val = shell_db.getSetting(key) catch return default;
    return val orelse default;
}

/// Set a config value in settings table
pub fn setConfig(key: []const u8, value: []const u8) void {
    if (!db_initialized) {
        std.debug.print("config: database not available\n", .{});
        return;
    }
    shell_db.setSetting(key, value) catch |err|
        std.debug.print("config: db error: {}\n", .{err});
}

fn builtinConfig(args: []const []const u8) bool {
    if (!db_initialized) {
        std.debug.print("config: database not available\n", .{});
        return true;
    }
    if (args.len < 2) {
        // List all settings
        var result = query_mod.executeQuery(shell_db, alloc, "SELECT key, value FROM settings ORDER BY key") catch return true;
        defer result.deinit();
        if (result.rows.items.len == 0) {
            std.debug.print("No settings configured.\n", .{});
            std.debug.print("Usage: config KEY VALUE  or  config KEY (to view)\n", .{});
        } else {
            for (result.rows.items) |row| {
                if (row.items.len >= 2)
                    std.debug.print("  {s} = {s}\n", .{ row.items[0], row.items[1] });
            }
        }
        return true;
    }
    if (args.len == 2) {
        // Get single key
        const key = args[1];
        if (std.mem.eql(u8, key, "--help") or std.mem.eql(u8, key, "-h")) {
            printConfigHelp();
            return true;
        }
        if (shell_db.getSetting(key) catch null) |val| {
            std.debug.print("{s} = {s}\n", .{ key, val });
            alloc.free(val);
        } else {
            std.debug.print("config: {s}: not set\n", .{key});
        }
        return true;
    }
    if (args.len >= 3) {
        const key = args[1];
        // Special case: "config KEY --unset"
        if (std.mem.eql(u8, args[2], "--unset")) {
            shell_db.removeSetting(key) catch |err|
                std.debug.print("config: {}\n", .{err});
            return true;
        }
        // Join remaining args as value (allows spaces without quoting)
        var val_buf: [2048]u8 = undefined;
        var val_len: usize = 0;
        for (args[2..], 0..) |arg, i| {
            if (i > 0 and val_len < val_buf.len) {
                val_buf[val_len] = ' ';
                val_len += 1;
            }
            const copy_len = @min(arg.len, val_buf.len - val_len);
            @memcpy(val_buf[val_len .. val_len + copy_len], arg[0..copy_len]);
            val_len += copy_len;
        }
        const value = val_buf[0..val_len];
        setConfig(key, value);
        std.debug.print("{s} = {s}\n", .{ key, value });
        return true;
    }
    return true;
}

fn printConfigHelp() void {
    std.debug.print(
        \\Usage: config [KEY [VALUE]]
        \\
        \\  config                 List all settings
        \\  config KEY             Show value of KEY
        \\  config KEY VALUE       Set KEY to VALUE
        \\  config KEY --unset     Remove KEY
        \\
        \\Prompt template (PS1):
        \\  config PS1 \\u:\\w$     Set prompt template
        \\
        \\  Escape sequences:
        \\    \\u   Username          \\h   Hostname
        \\    \\w   Working dir (~)   \\W   Basename of cwd
        \\    \\?   Exit code         \\!   Exit indicator
        \\    \\$   # if root, $ otherwise
        \\    \\e[  Start ANSI code   \\n   Newline
        \\    \\S{{SQL}}  Inline SQL query (first cell of result)
        \\
        \\  SQL prompt examples:
        \\    config PS1 [\\S{{SELECT count(*) FROM history}}] \\w$ 
        \\    config PS1 \\S{{SELECT count(*) FROM aliases}}a \\w$ 
        \\
    , .{});
}

fn builtinCd(args: []const []const u8) bool {
    const target = if (args.len > 1) args[1] else std.posix.getenv("HOME") orelse "/";
    var resolved: []const u8 = target;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.mem.startsWith(u8, target, "~")) {
        if (std.posix.getenv("HOME")) |home| {
            const rest = target[1..];
            resolved = std.fmt.bufPrint(&buf, "{s}{s}", .{ home, rest }) catch target;
        }
    }
    const dir = std.fs.cwd().openDir(resolved, .{}) catch |err| {
        std.debug.print("cd: {s}: {}\n", .{ resolved, err });
        return true;
    };
    dir.setAsCwd() catch |err| {
        std.debug.print("cd: {s}: {}\n", .{ resolved, err });
    };
    return true;
}

fn builtinPwd(_: []const []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&buf) catch {
        std.debug.print("pwd: error\n", .{});
        return true;
    };
    std.debug.print("{s}\n", .{cwd});
    return true;
}

fn builtinExit(_: []const []const u8) bool {
    if (db_initialized) shell_db.close();
    std.process.exit(0);
}

fn builtinExport(args: []const []const u8) bool {
    if (args.len < 2) {
        if (!db_initialized) return true;
        var entries = shell_db.getAllEnv() catch return true;
        defer {
            for (entries.items) |entry| {
                alloc.free(entry.key);
                alloc.free(entry.value);
            }
            entries.deinit(alloc);
        }
        for (entries.items) |entry|
            std.debug.print("export {s}=\"{s}\"\n", .{ entry.key, entry.value });
        return true;
    }
    for (args[1..]) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const key = arg[0..eq_pos];
            const value = arg[eq_pos + 1 ..];
            const ckey = alloc.dupeZ(u8, key) catch continue;
            defer alloc.free(ckey);
            const cval = alloc.dupeZ(u8, value) catch continue;
            defer alloc.free(cval);
            _ = c.setenv(ckey.ptr, cval.ptr, 1);
            if (db_initialized)
                shell_db.setEnv(key, value) catch |err|
                    std.debug.print("export: db error: {}\n", .{err});
        } else {
            std.debug.print("export: invalid format: {s} (expected KEY=VALUE)\n", .{arg});
        }
    }
    return true;
}

fn builtinUnset(args: []const []const u8) bool {
    if (args.len < 2) {
        std.debug.print("unset: usage: unset VAR [VAR...]\n", .{});
        return true;
    }
    for (args[1..]) |key| {
        const ckey = alloc.dupeZ(u8, key) catch continue;
        defer alloc.free(ckey);
        _ = c.unsetenv(ckey.ptr);
        if (db_initialized) shell_db.removeEnv(key) catch {};
    }
    return true;
}

fn builtinHistory(args: []const []const u8) bool {
    if (args.len >= 3 and std.mem.eql(u8, args[1], "search")) {
        if (!db_initialized) {
            std.debug.print("history: database not available\n", .{});
            return true;
        }
        var entries = shell_db.searchHistory(args[2], 25) catch return true;
        defer {
            for (entries.items) |entry| {
                alloc.free(entry.command);
                alloc.free(entry.cwd);
            }
            entries.deinit(alloc);
        }
        for (entries.items) |entry| {
            const exit_mark: []const u8 = if (entry.exit_code != 0) " ✘" else "";
            std.debug.print("  [{d}]{s}  {s}  ({s})\n", .{ entry.timestamp, exit_mark, entry.command, entry.cwd });
        }
        return true;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "stats")) {
        if (!db_initialized) {
            std.debug.print("history: database not available\n", .{});
            return true;
        }
        const count = shell_db.historyCount() catch 0;
        std.debug.print("Total commands in database: {d}\nDatabase: {s}\n", .{ count, db_path });
        return true;
    }

    if (!db_initialized) {
        std.debug.print("history: database not available\n", .{});
        return true;
    }
    var entries = shell_db.getHistory(50) catch {
        std.debug.print("history: database error\n", .{});
        return true;
    };
    defer entries.deinit(alloc);
    for (entries.items, 1..) |e, i| {
        std.debug.print("  {d:>4}  {s}\n", .{ i, e.command });
    }
    return true;
}

fn builtinAlias(args: []const []const u8) bool {
    if (!db_initialized) {
        std.debug.print("alias: database not available\n", .{});
        return true;
    }
    if (args.len < 2) {
        var entries = shell_db.getAllAliases() catch return true;
        defer {
            for (entries.items) |entry| {
                alloc.free(entry.name);
                alloc.free(entry.command);
            }
            entries.deinit(alloc);
        }
        for (entries.items) |entry|
            std.debug.print("alias {s}='{s}'\n", .{ entry.name, entry.command });
        return true;
    }
    for (args[1..]) |arg| {
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            const name = arg[0..eq_pos];
            var value = arg[eq_pos + 1 ..];
            if (value.len >= 2) {
                if ((value[0] == '\'' and value[value.len - 1] == '\'') or
                    (value[0] == '"' and value[value.len - 1] == '"'))
                    value = value[1 .. value.len - 1];
            }
            shell_db.setAlias(name, value) catch |err|
                std.debug.print("alias: db error: {}\n", .{err});
        } else {
            if (shell_db.getAlias(arg) catch null) |cmd| {
                std.debug.print("alias {s}='{s}'\n", .{ arg, cmd });
                alloc.free(cmd);
            } else {
                std.debug.print("alias: {s}: not found\n", .{arg});
            }
        }
    }
    return true;
}

fn builtinUnalias(args: []const []const u8) bool {
    if (!db_initialized) {
        std.debug.print("unalias: database not available\n", .{});
        return true;
    }
    if (args.len < 2) {
        std.debug.print("unalias: usage: unalias NAME [NAME...]\n", .{});
        return true;
    }
    for (args[1..]) |name|
        shell_db.removeAlias(name) catch |err|
            std.debug.print("unalias: {s}: {}\n", .{ name, err });
    return true;
}

fn builtinDbInfo(_: []const []const u8) bool {
    if (!db_initialized) {
        std.debug.print("Database: not connected\n", .{});
        return true;
    }
    const hist_count = shell_db.historyCount() catch 0;
    var env_entries = shell_db.getAllEnv() catch return true;
    defer {
        for (env_entries.items) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        env_entries.deinit(alloc);
    }
    var alias_entries = shell_db.getAllAliases() catch return true;
    defer {
        for (alias_entries.items) |entry| {
            alloc.free(entry.name);
            alloc.free(entry.command);
        }
        alias_entries.deinit(alloc);
    }
    std.debug.print(
        \\zish database
        \\  Path:         {s}
        \\  History:      {d} commands
        \\  Environment:  {d} variables
        \\  Aliases:      {d} entries
        \\
    , .{ db_path, hist_count, env_entries.items.len, alias_entries.items.len });
    return true;
}

fn builtinHelp(_: []const []const u8) bool {
    std.debug.print(
        \\zish - a minimal shell written in Zig (SQLite-backed)
        \\
        \\Builtins:
        \\  cd [dir]              Change directory (~ supported)
        \\  pwd                   Print working directory
        \\  exit                  Exit the shell
        \\  export KEY=VAL        Set & persist environment variable
        \\  unset KEY             Remove environment variable
        \\  alias name=command    Set & persist alias
        \\  unalias name          Remove alias
        \\  history               Show command history
        \\  history search PREFIX Search history by prefix (from DB)
        \\  history stats         Show history statistics
        \\  query [--json|--csv]  Execute SQL on the zish database
        \\  config [KEY [VALUE]] Get/set shell configuration
        \\  dbinfo                Show database information
        \\  help                  Show this help
        \\
        \\Features:
        \\  cmd1 | cmd2           Pipes
        \\  cmd1 && cmd2          Run cmd2 only if cmd1 succeeds
        \\  cmd1 || cmd2          Run cmd2 only if cmd1 fails
        \\  $(cmd)                Command substitution
        \\  *.txt                 Glob expansion
        \\  cmd > file            Redirect stdout
        \\  cmd >> file           Append stdout
        \\  cmd < file            Redirect stdin
        \\  Arrow Up/Down         Prefix-based history search
        \\
        \\Database: ~/.zish.db (portable, take it with you!)
        \\
    , .{});
    return true;
}
