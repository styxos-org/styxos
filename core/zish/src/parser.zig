// zish parser - tokenizer, pipeline/list parsing, expansion
// License: GPL-3.0-or-later

const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
});

// Manual glob declarations (avoids macOS glob.h BlockPointer issue)
const GLOB_NOSORT: c_int = 0x0020;
const GLOB_TILDE: c_int = if (@import("builtin").os.tag == .macos) 0x2000 else 0x1000;

const glob_t = if (@import("builtin").os.tag == .macos)
    extern struct {
        gl_pathc: usize,
        gl_matchc: c_int = 0,
        gl_offs: usize = 0,
        gl_flags: c_int = 0,
        gl_pathv: [*c][*c]u8 = undefined,
    }
else
    extern struct {
        gl_pathc: usize,
        gl_pathv: [*c][*c]u8 = undefined,
        gl_offs: usize = 0,
        gl_flags: c_int = 0,
    };

extern fn glob(pattern: [*:0]const u8, flags: c_int, errfunc: ?*const anyopaque, pglob: *glob_t) c_int;
extern fn globfree(pglob: *glob_t) void;

// Module state for command substitution (zish -c instead of /bin/sh -c)
var self_exe: []const u8 = "/bin/sh";
var db_path: []const u8 = "";
var use_self: bool = false;

pub fn initSubstitution(exe_path: []const u8, db: []const u8) void {
    self_exe = exe_path;
    db_path = db;
    use_self = true;
}

pub const Redirect = struct {
    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stdout_append: bool = false,
};

pub const Command = struct {
    args: std.ArrayList([]const u8),
    redirect: Redirect,

    pub fn init() Command {
        return .{ .args = .empty, .redirect = .{} };
    }

    pub fn deinit(self: *Command, alloc: std.mem.Allocator) void {
        self.args.deinit(alloc);
    }
};

/// A pipeline is a sequence of commands connected by pipes.
/// A command list is a sequence of pipelines connected by && or ||.
pub const Connector = enum { none, @"and", @"or" };

pub const PipelineEntry = struct {
    pipeline: std.ArrayList(Command),
    connector: Connector, // how this pipeline connects to the NEXT one

    pub fn deinit(self: *PipelineEntry, alloc: std.mem.Allocator) void {
        for (self.pipeline.items) |*cmd| cmd.deinit(alloc);
        self.pipeline.deinit(alloc);
    }
};

// ── Tokenizer ────────────────────────────────────────────────────────

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,
    // Track allocated tokens so they can be referenced after tokenizer is gone
    allocated: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Tokenizer) void {
        // Note: don't free the strings here - they're owned by Command.args
        // and will be valid as long as the commands are alive.
        // We only free the tracking list itself.
        self.allocated.deinit(self.alloc);
    }

    pub fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.input.len and self.input[self.pos] == ' ')
            self.pos += 1;
        if (self.pos >= self.input.len) return null;

        // Two-character operators first
        if (self.pos + 1 < self.input.len) {
            const two = self.input[self.pos .. self.pos + 2];
            if (std.mem.eql(u8, two, "&&")) {
                self.pos += 2;
                return "&&";
            }
            if (std.mem.eql(u8, two, "||")) {
                self.pos += 2;
                return "||";
            }
            if (std.mem.eql(u8, two, ">>")) {
                self.pos += 2;
                return ">>";
            }
        }

        if (self.input[self.pos] == '|') {
            self.pos += 1;
            return "|";
        }
        if (self.input[self.pos] == '>') {
            self.pos += 1;
            return ">";
        }
        if (self.input[self.pos] == '<') {
            self.pos += 1;
            return "<";
        }

        // Token with possible embedded quotes
        const start = self.pos;
        var has_quotes = false;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"' or ch == '\'') {
                has_quotes = true;
                const quote = ch;
                self.pos += 1;
                while (self.pos < self.input.len and self.input[self.pos] != quote)
                    self.pos += 1;
                if (self.pos < self.input.len) self.pos += 1;
            } else if (ch == ' ' or ch == '|' or ch == '>' or ch == '<' or ch == '&') {
                if (ch == '&' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '&') {
                    break;
                } else if (ch != '&') {
                    break;
                } else {
                    self.pos += 1;
                }
            } else {
                self.pos += 1;
            }
        }

        if (!has_quotes) {
            return self.input[start..self.pos];
        }

        // Strip quotes - allocate a new string that outlives the tokenizer
        var buf: std.ArrayList(u8) = .empty;
        var j: usize = start;
        while (j < self.pos) {
            const ch = self.input[j];
            if (ch == '"' or ch == '\'') {
                const quote = ch;
                j += 1;
                while (j < self.pos and self.input[j] != quote) {
                    buf.append(self.alloc, self.input[j]) catch return null;
                    j += 1;
                }
                if (j < self.pos) j += 1;
            } else {
                buf.append(self.alloc, ch) catch return null;
                j += 1;
            }
        }
        const result = buf.toOwnedSlice(self.alloc) catch return null;
        self.allocated.append(self.alloc, result) catch {};
        return result;
    }
};

// ── Pipeline Parser ──────────────────────────────────────────────────

fn parsePipeline(alloc: std.mem.Allocator, tokens: *Tokenizer) !std.ArrayList(Command) {
    var pipeline: std.ArrayList(Command) = .empty;
    errdefer {
        for (pipeline.items) |*cmd_item| cmd_item.deinit(alloc);
        pipeline.deinit(alloc);
    }

    var current = Command.init();

    while (tokens.next()) |token| {
        // Stop at list operators - put them back by rewinding
        if (std.mem.eql(u8, token, "&&") or std.mem.eql(u8, token, "||")) {
            // We can't rewind the tokenizer, so we handle this in parseCommandList
            // by checking the token there. Instead, we use a different approach:
            // parsePipeline is called with knowledge of where to stop.
            // For simplicity, we save current pipeline and signal the connector.
            if (current.args.items.len > 0) {
                try pipeline.append(alloc, current);
                current = Command.init();
            }
            // Rewind: we need to back up. Since tokenizer doesn't support rewind,
            // we subtract the token length from pos.
            tokens.pos -= token.len;
            break;
        }

        if (std.mem.eql(u8, token, "|")) {
            if (current.args.items.len > 0) {
                try pipeline.append(alloc, current);
                current = Command.init();
            }
        } else if (std.mem.eql(u8, token, ">>")) {
            if (tokens.next()) |file| {
                current.redirect.stdout_file = file;
                current.redirect.stdout_append = true;
            }
        } else if (std.mem.eql(u8, token, ">")) {
            if (tokens.next()) |file| {
                current.redirect.stdout_file = file;
                current.redirect.stdout_append = false;
            }
        } else if (std.mem.eql(u8, token, "<")) {
            if (tokens.next()) |file|
                current.redirect.stdin_file = file;
        } else {
            try current.args.append(alloc, token);
        }
    }

    if (current.args.items.len > 0) {
        try pipeline.append(alloc, current);
    } else {
        current.deinit(alloc);
    }

    return pipeline;
}

/// Parse a full command line into a list of pipelines connected by && / ||
pub fn parseCommandList(alloc: std.mem.Allocator, line: []const u8) !std.ArrayList(PipelineEntry) {
    var list: std.ArrayList(PipelineEntry) = .empty;
    errdefer {
        for (list.items) |*entry| entry.deinit(alloc);
        list.deinit(alloc);
    }

    var tokens = Tokenizer{ .input = line, .alloc = alloc };
    defer tokens.deinit();

    while (true) {
        const pipeline = try parsePipeline(alloc, &tokens);
        if (pipeline.items.len == 0) {
            // Empty pipeline at end of input
            var p = pipeline;
            p.deinit(alloc);
            break;
        }

        // Check for connector after this pipeline
        var connector: Connector = .none;

        // Skip whitespace manually
        while (tokens.pos < tokens.input.len and tokens.input[tokens.pos] == ' ')
            tokens.pos += 1;

        if (tokens.pos + 1 < tokens.input.len) {
            const two = tokens.input[tokens.pos .. tokens.pos + 2];
            if (std.mem.eql(u8, two, "&&")) {
                connector = .@"and";
                tokens.pos += 2;
            } else if (std.mem.eql(u8, two, "||")) {
                connector = .@"or";
                tokens.pos += 2;
            }
        }

        try list.append(alloc, .{
            .pipeline = pipeline,
            .connector = connector,
        });

        if (connector == .none) break;
    }

    return list;
}

// ── Variable & Command Substitution Expansion ────────────────────────

pub fn expandVariables(alloc: std.mem.Allocator, line: []const u8, last_exit_code: i32) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '$' and i + 1 < line.len) {
            // $? - last exit code
            if (line[i + 1] == '?') {
                var buf: [16]u8 = undefined;
                const code_str = std.fmt.bufPrint(&buf, "{d}", .{last_exit_code}) catch "0";
                try result.appendSlice(alloc, code_str);
                i += 2;
                continue;
            }

            // $(...) - command substitution
            if (line[i + 1] == '(') {
                const cmd_start = i + 2;
                var depth: usize = 1;
                var j: usize = cmd_start;
                while (j < line.len and depth > 0) {
                    if (line[j] == '(') depth += 1;
                    if (line[j] == ')') depth -= 1;
                    if (depth > 0) j += 1;
                }
                if (depth == 0) {
                    const inner_cmd = line[cmd_start..j];
                    const output = try executeCommandSubstitution(alloc, inner_cmd);
                    defer alloc.free(output);
                    try result.appendSlice(alloc, output);
                    i = j + 1; // skip past closing )
                    continue;
                }
            }

            // $VAR - variable expansion
            i += 1;
            const start = i;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_'))
                i += 1;
            const var_name = line[start..i];
            if (std.posix.getenv(var_name)) |val|
                try result.appendSlice(alloc, val);
        } else {
            try result.append(alloc, line[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(alloc);
}

/// Execute a command in a subshell and capture its stdout
fn executeCommandSubstitution(alloc: std.mem.Allocator, cmd: []const u8) ![]const u8 {
    const posix = std.posix;
    const pipe_fds = try posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];

    const pid = try posix.fork();
    if (pid == 0) {
        // Child: redirect stdout to pipe, exec via /bin/sh -c
        posix.close(read_fd);
        posix.dup2(write_fd, posix.STDOUT_FILENO) catch std.process.exit(1);
        posix.close(write_fd);

        const ccmd = alloc.dupeZ(u8, cmd) catch std.process.exit(1);

        if (use_self) {
            // Use zish itself so builtins, aliases, and DB work in $()
            const cexe = alloc.dupeZ(u8, self_exe) catch std.process.exit(1);
            const cdb = alloc.dupeZ(u8, db_path) catch std.process.exit(1);
            const argv = [_:null]?[*:0]const u8{ cexe.ptr, "--db", cdb.ptr, "-c", ccmd.ptr, null };
            _ = c.execvp(cexe.ptr, @ptrCast(&argv));
        } else {
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", ccmd.ptr, null };
            _ = c.execvp("/bin/sh", @ptrCast(&argv));
        }
        std.process.exit(127);
    }

    // Parent: read from pipe
    posix.close(write_fd);

    var output: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = c.read(@intCast(read_fd), &buf, buf.len);
        if (n <= 0) break;
        try output.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    posix.close(read_fd);

    _ = posix.waitpid(pid, 0);

    // Trim trailing newlines (like bash does)
    var result = try output.toOwnedSlice(alloc);
    while (result.len > 0 and (result[result.len - 1] == '\n' or result[result.len - 1] == '\r')) {
        result = result[0 .. result.len - 1];
    }
    return result;
}

// ── Glob Expansion ───────────────────────────────────────────────────

/// Check if a string contains glob characters
fn hasGlobChars(s: []const u8) bool {
    for (s) |ch| {
        if (ch == '*' or ch == '?' or ch == '[') return true;
    }
    return false;
}

/// Expand glob patterns in command arguments using POSIX glob(3)
pub fn expandGlobs(alloc: std.mem.Allocator, pipeline: *std.ArrayList(Command)) !void {
    for (pipeline.items) |*cmd| {
        var new_args: std.ArrayList([]const u8) = .empty;
        errdefer new_args.deinit(alloc);

        for (cmd.args.items) |arg| {
            if (hasGlobChars(arg)) {
                var expanded = try globExpand(alloc, arg);
                defer {
                    for (expanded.items) |item| alloc.free(item);
                    expanded.deinit(alloc);
                }
                if (expanded.items.len > 0) {
                    for (expanded.items) |item| {
                        try new_args.append(alloc, try alloc.dupe(u8, item));
                    }
                } else {
                    // No matches: keep original pattern (like bash default)
                    try new_args.append(alloc, arg);
                }
            } else {
                try new_args.append(alloc, arg);
            }
        }

        cmd.args.deinit(alloc);
        cmd.args = new_args;
    }
}

fn globExpand(alloc: std.mem.Allocator, pattern: []const u8) !std.ArrayList([]const u8) {
    var results: std.ArrayList([]const u8) = .empty;
    errdefer results.deinit(alloc);

    const cpattern = try alloc.dupeZ(u8, pattern);
    defer alloc.free(cpattern);

    var glob_result: glob_t = std.mem.zeroes(glob_t);
    const ret = glob(cpattern.ptr, GLOB_NOSORT | GLOB_TILDE, null, &glob_result);
    if (ret != 0) return results; // no matches, don't call globfree

    defer globfree(&glob_result);

    var i: usize = 0;
    while (i < glob_result.gl_pathc) : (i += 1) {
        const path = glob_result.gl_pathv[i] orelse continue;
        const slice = std.mem.sliceTo(path, 0);
        try results.append(alloc, try alloc.dupe(u8, slice));
    }

    return results;
}

// ── Alias Expansion ──────────────────────────────────────────────────

pub fn expandAliases(
    alloc: std.mem.Allocator,
    line: []const u8,
    lookupFn: *const fn ([]const u8) ?[]const u8,
) ![]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    while (i < line.len and line[i] != ' ') i += 1;
    const first_word = line[start..i];

    if (first_word.len == 0) return line;

    if (lookupFn(first_word)) |replacement| {
        const rest = line[i..];
        const expanded = try std.fmt.allocPrint(alloc, "{s}{s}", .{ replacement, rest });
        alloc.free(replacement);
        return expanded;
    }

    return line;
}
