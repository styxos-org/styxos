// zish - A minimal shell written in Zig with GNU Readline + SQLite
// License: GPL-3.0-or-later

const std = @import("std");
const posix = std.posix;
const db_mod = @import("db.zig");
const parser = @import("parser.zig");
const builtins = @import("builtins.zig");
const exec = @import("exec.zig");
const Db = db_mod.Db;

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("signal.h");
    @cInclude("readline/readline.h");
    @cInclude("readline/history.h");
});

// ── Globals ──────────────────────────────────────────────────────────

var shell_db: Db = undefined;
var db_initialized: bool = false;
var allocator: std.mem.Allocator = undefined;
var last_exit_code: i32 = 0;
var db_path_global: []const u8 = "";
var self_exe_path: []const u8 = "zish";

// ── Readline Setup ───────────────────────────────────────────────────

fn setupReadline() void {
    var b1 = "\"\\e[A\": history-search-backward".*;
    var b2 = "\"\\e[B\": history-search-forward".*;
    var b3 = "\"\\C-p\": history-search-backward".*;
    var b4 = "\"\\C-n\": history-search-forward".*;
    _ = c.rl_parse_and_bind(&b1);
    _ = c.rl_parse_and_bind(&b2);
    _ = c.rl_parse_and_bind(&b3);
    _ = c.rl_parse_and_bind(&b4);

    // Set up tab completion
    c.rl_attempted_completion_function = &zishCompletion;
}

// ── Tab Completion ───────────────────────────────────────────────────

fn zishCompletion(text: [*c]const u8, start: c_int, _: c_int) callconv(.c) [*c][*c]u8 {
    if (start == 0) {
        // First word: complete builtins and aliases
        const result = c.rl_completion_matches(text, &commandGenerator);
        if (result != null) return result;
    }
    // Not first word or no matches: let readline do filename completion
    // Return null pointer (as non-optional type)
    return @ptrFromInt(0);
}

/// Generator function called repeatedly by readline to get matches.
/// On first call (state=0), initialize. Return next match or null when done.
fn commandGenerator(text: [*c]const u8, state: c_int) callconv(.c) [*c]u8 {
    const State = struct {
        var builtin_index: usize = 0;
        var alias_list: ?std.ArrayList(db_mod.AliasEntry) = null;
        var alias_index: usize = 0;
    };

    const prefix = std.mem.sliceTo(text, 0);

    if (state == 0) {
        // Reset iteration
        State.builtin_index = 0;
        // Free previous alias list if any
        if (State.alias_list) |*list| {
            for (list.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.command);
            }
            list.deinit(allocator);
        }
        State.alias_list = null;
        State.alias_index = 0;

        // Load aliases from DB
        if (db_initialized) {
            State.alias_list = shell_db.getAllAliases() catch null;
        }
    }

    // Try builtins first
    const names = builtins.getBuiltinNames();
    while (State.builtin_index < names.len) {
        const name = names[State.builtin_index].name;
        State.builtin_index += 1;
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            // readline expects malloc'd strings (it will free them)
            const cname = allocator.dupeZ(u8, name) catch continue;
            defer allocator.free(cname);
            const dup = c.strdup(cname.ptr) orelse continue;
            return dup;
        }
    }

    // Then try aliases
    if (State.alias_list) |list| {
        while (State.alias_index < list.items.len) {
            const name = list.items[State.alias_index].name;
            State.alias_index += 1;
            if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
                const cname = allocator.dupeZ(u8, name) catch continue;
                defer allocator.free(cname);
                const dup = c.strdup(cname.ptr) orelse continue;
                return dup;
            }
        }
    }

    return @ptrFromInt(0);
}

fn loadHistoryFromDb() void {
    if (!db_initialized) return;
    var entries = shell_db.getHistory(5000) catch return;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.command);
            allocator.free(entry.cwd);
        }
        entries.deinit(allocator);
    }
    for (entries.items) |entry| {
        const cstr = allocator.dupeZ(u8, entry.command) catch continue;
        defer allocator.free(cstr);
        _ = c.add_history(cstr.ptr);
    }
}

fn loadEnvFromDb() void {
    if (!db_initialized) return;
    var entries = shell_db.getAllEnv() catch return;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        entries.deinit(allocator);
    }
    for (entries.items) |entry| {
        const ckey = allocator.dupeZ(u8, entry.key) catch continue;
        defer allocator.free(ckey);
        const cval = allocator.dupeZ(u8, entry.value) catch continue;
        defer allocator.free(cval);
        _ = c.setenv(ckey.ptr, cval.ptr, 1);
    }
}

// ── Prompt ────────────────────────────────────────────────────────────

const default_ps1 = "\\!\\e[1;32m\\u\\e[0m:\\e[1;34m\\w\\e[0m$ ";

fn buildPrompt(buf: []u8) []const u8 {
    const template = builtins.getConfig("PS1", default_ps1);
    defer {
        // If getConfig returned an allocated string (not the default), free it
        if (template.ptr != default_ps1.ptr) allocator.free(template);
    }

    return expandPrompt(buf, template);
}

fn expandPrompt(buf: []u8, template: []const u8) []const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "/???";

    const home = std.posix.getenv("HOME") orelse "";
    var tilde_buf: [std.fs.max_path_bytes]u8 = undefined;
    var display_cwd: []const u8 = cwd;
    if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
        const rest = cwd[home.len..];
        const written = std.fmt.bufPrint(&tilde_buf, "~{s}", .{rest}) catch cwd;
        display_cwd = written;
    }

    const user = std.posix.getenv("USER") orelse "?";
    var hostname_buf: [256]u8 = undefined;
    const hostname = getHostname(&hostname_buf);
    const exit_indicator: []const u8 = if (last_exit_code != 0) "\x1b[1;31m✘\x1b[0m " else "";
    const shell_char: []const u8 = if (std.mem.eql(u8, user, "root")) "#" else "$";

    // Basename of cwd
    const basename = if (std.mem.lastIndexOf(u8, cwd, "/")) |pos| cwd[pos + 1 ..] else cwd;

    var len: usize = 0;
    var i: usize = 0;
    while (i < template.len and len < buf.len) {
        if (template[i] == '\\' and i + 1 < template.len) {
            const next = template[i + 1];
            switch (next) {
                'u' => {
                    len = appendStr(buf, len, user);
                    i += 2;
                },
                'h' => {
                    len = appendStr(buf, len, hostname);
                    i += 2;
                },
                'w' => {
                    len = appendStr(buf, len, display_cwd);
                    i += 2;
                },
                'W' => {
                    len = appendStr(buf, len, basename);
                    i += 2;
                },
                '?' => {
                    var code_buf: [16]u8 = undefined;
                    const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{last_exit_code}) catch "0";
                    len = appendStr(buf, len, code_str);
                    i += 2;
                },
                '!' => {
                    len = appendStr(buf, len, exit_indicator);
                    i += 2;
                },
                '$' => {
                    len = appendStr(buf, len, shell_char);
                    i += 2;
                },
                'S' => {
                    // \S{SQL} - execute SQL, insert first result cell
                    if (i + 2 < template.len and template[i + 2] == '{') {
                        const sql_start = i + 3;
                        var depth: usize = 1;
                        var j: usize = sql_start;
                        while (j < template.len and depth > 0) {
                            if (template[j] == '{') depth += 1;
                            if (template[j] == '}') depth -= 1;
                            if (depth > 0) j += 1;
                        }
                        if (depth == 0) {
                            const sql = template[sql_start..j];
                            const result = execPromptSql(sql);
                            len = appendStr(buf, len, result);
                            if (result.ptr != "?"[0..].ptr)
                                allocator.free(result);
                            i = j + 1;
                        } else {
                            // Unclosed brace, pass through
                            len = appendStr(buf, len, "\\S");
                            i += 2;
                        }
                    } else {
                        len = appendStr(buf, len, "\\S");
                        i += 2;
                    }
                },
                'e' => {
                    // \e → ESC character (0x1b)
                    if (len < buf.len) {
                        buf[len] = 0x1b;
                        len += 1;
                    }
                    i += 2;
                },
                'n' => {
                    if (len < buf.len) {
                        buf[len] = '\n';
                        len += 1;
                    }
                    i += 2;
                },
                '\\' => {
                    if (len < buf.len) {
                        buf[len] = '\\';
                        len += 1;
                    }
                    i += 2;
                },
                else => {
                    // Unknown escape, pass through
                    if (len < buf.len) {
                        buf[len] = '\\';
                        len += 1;
                    }
                    i += 1;
                },
            }
        } else {
            if (len < buf.len) {
                buf[len] = template[i];
                len += 1;
            }
            i += 1;
        }
    }

    return buf[0..len];
}

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    var p = pos;
    for (s) |ch| {
        if (p >= buf.len) break;
        buf[p] = ch;
        p += 1;
    }
    return p;
}

/// Execute SQL for prompt \S{} escapes, return first cell of first row
fn execPromptSql(sql: []const u8) []const u8 {
    if (!db_initialized) return "?";
    const query_mod = @import("query.zig");
    var result = query_mod.executeQuery(&shell_db, allocator, sql) catch return "?";
    defer result.deinit();
    if (result.rows.items.len > 0 and result.rows.items[0].items.len > 0) {
        // Dupe the string so it survives result.deinit()
        return allocator.dupe(u8, result.rows.items[0].items[0]) catch "?";
    }
    return "?";
}

fn getHostname(buf: []u8) []const u8 {
    // Try environment first, then /etc/hostname
    if (std.posix.getenv("HOSTNAME")) |h| return h;
    const file = std.fs.openFileAbsolute("/etc/hostname", .{}) catch return "localhost";
    defer file.close();
    const n = file.read(buf) catch return "localhost";
    // Strip trailing newline
    var len = n;
    while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == '\r')) len -= 1;
    return buf[0..len];
}

// ── Signal Handling ───────────────────────────────────────────────────

var sigint_received: bool = false;

fn handleSigint(_: c_int) callconv(.c) void {
    sigint_received = true;
    // Tell readline to stop and redisplay on a new line
    // We write a newline directly since we can't use std.debug.print in a signal handler
    _ = std.posix.write(std.posix.STDERR_FILENO, "\n") catch {};
    _ = c.rl_on_new_line();
    c.rl_redisplay();
}

// ── Main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    allocator = gpa.allocator();

    const home = std.posix.getenv("HOME") orelse "/tmp";
    db_path_global = try std.fmt.allocPrint(allocator, "{s}/.zish.db", .{home});

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Capture our own path for command substitution (zish -c instead of /bin/sh -c)
    if (args.len > 0) {
        self_exe_path = try allocator.dupe(u8, args[0]);
    }

    var cmd_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
            i += 1;
            db_path_global = args[i];
        } else if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            i += 1;
            cmd_arg = args[i];
        }
    }

    shell_db = Db.open(allocator, db_path_global) catch |err| {
        std.debug.print("zish: warning: could not open database {s}: {}\n", .{ db_path_global, err });
        std.debug.print("zish: running without persistence\n", .{});
        db_initialized = false;
        builtins.init(allocator, &shell_db, false, db_path_global);
        parser.initSubstitution(self_exe_path, db_path_global);
        if (cmd_arg) |cmd| {
            const code = executeOneLine(cmd);
            std.process.exit(@intCast(if (code >= 0) @as(u32, @intCast(code)) else 1));
        }
        runShellLoop();
        return;
    };
    db_initialized = true;

    builtins.init(allocator, &shell_db, true, db_path_global);
    parser.initSubstitution(self_exe_path, db_path_global);
    loadEnvFromDb();

    if (cmd_arg) |cmd| {
        // Non-interactive: execute command and exit
        const code = executeOneLine(cmd);
        shell_db.close();
        std.process.exit(@intCast(if (code >= 0) @as(u32, @intCast(code)) else 1));
    }

    loadHistoryFromDb();
    runShellLoop();

    if (db_initialized) shell_db.close();
}

/// Execute a single command line (for -c mode), returns exit code
fn executeOneLine(line: []const u8) i32 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const aliased = parser.expandAliases(a, line, builtins.lookupAlias) catch line;
    const expanded = parser.expandVariables(a, aliased, last_exit_code) catch aliased;

    var cmd_list = parser.parseCommandList(a, expanded) catch |err| {
        std.debug.print("zish: parse error: {}\n", .{err});
        return 1;
    };

    return exec.executeCommandList(
        a,
        &cmd_list,
        builtins.findBuiltin,
    ) catch |err| blk: {
        std.debug.print("zish: execution error: {}\n", .{err});
        break :blk 1;
    };
}

fn runShellLoop() void {
    setupReadline();

    // Let readline handle signals (SIGINT etc.) - this is the default,
    // but set it explicitly to be clear. Readline will clean up the
    // terminal state and throw rl_readline_state on Ctrl-C.
    // remove for macOS compat.
    // c.rl_catch_signals = 1;

    // Set a custom SIGINT handler that tells readline to abort the current line
    _ = c.signal(c.SIGINT, &handleSigint);

    var prompt_buf: [1024]u8 = undefined;

    while (true) {
        const prompt = buildPrompt(&prompt_buf);
        const cprompt = allocator.dupeZ(u8, prompt) catch continue;
        defer allocator.free(cprompt);

        const line_ptr = c.readline(cprompt.ptr);
        if (line_ptr == null) {
            if (sigint_received) {
                sigint_received = false;
                continue;
            }
            std.debug.print("\n", .{});
            break;
        }
        sigint_received = false;

        const line_cstr: [*:0]const u8 = line_ptr;
        const line = std.mem.sliceTo(line_cstr, 0);

        if (line.len == 0) {
            c.free(line_ptr);
            continue;
        }

        _ = c.add_history(line_cstr);

        // Per-line arena: all allocations for parsing/expansion are freed in one shot
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Expansion pipeline: aliases → variables/command substitution → parse → glob → execute
        const aliased = parser.expandAliases(a, line, builtins.lookupAlias) catch line;
        const expanded = parser.expandVariables(a, aliased, last_exit_code) catch aliased;

        var cmd_list = parser.parseCommandList(a, expanded) catch |err| {
            std.debug.print("zish: parse error: {}\n", .{err});
            c.free(line_ptr);
            continue;
        };

        last_exit_code = exec.executeCommandList(
            a,
            &cmd_list,
            builtins.findBuiltin,
        ) catch |err| blk: {
            std.debug.print("zish: execution error: {}\n", .{err});
            break :blk 1;
        };

        if (db_initialized) {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch "";
            shell_db.addHistory(line, cwd, last_exit_code) catch {};
        }

        c.free(line_ptr);
    }
}
