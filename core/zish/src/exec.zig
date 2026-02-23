// zish executor - fork, exec, pipes, redirects, command lists
// License: GPL-3.0-or-later

const std = @import("std");
const posix = std.posix;
const parser = @import("parser.zig");
const Command = parser.Command;

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
});

pub const BuiltinFn = *const fn (args: []const []const u8) bool;

fn executeExternal(
    alloc: std.mem.Allocator,
    cmd: *const Command,
    stdin_fd: ?i32,
    stdout_fd: ?i32,
) !posix.pid_t {
    if (cmd.args.items.len == 0) return error.EmptyCommand;

    var argv = try alloc.alloc(?[*:0]const u8, cmd.args.items.len + 1);
    defer alloc.free(argv);

    for (cmd.args.items, 0..) |arg, i|
        argv[i] = (try alloc.dupeZ(u8, arg)).ptr;
    argv[cmd.args.items.len] = null;

    const pid = try posix.fork();
    if (pid == 0) {
        // Child
        if (stdin_fd) |fd|
            posix.dup2(fd, posix.STDIN_FILENO) catch std.process.exit(1);
        if (stdout_fd) |fd|
            posix.dup2(fd, posix.STDOUT_FILENO) catch std.process.exit(1);

        if (cmd.redirect.stdin_file) |file| {
            const cfile = alloc.dupeZ(u8, file) catch std.process.exit(1);
            const fd = c.open(cfile.ptr, c.O_RDONLY);
            if (fd < 0) {
                std.debug.print("zish: {s}: No such file\n", .{file});
                std.process.exit(1);
            }
            posix.dup2(@intCast(fd), posix.STDIN_FILENO) catch std.process.exit(1);
        }
        if (cmd.redirect.stdout_file) |file| {
            const cfile = alloc.dupeZ(u8, file) catch std.process.exit(1);
            var flags: c_int = c.O_WRONLY | c.O_CREAT;
            if (cmd.redirect.stdout_append) {
                flags |= c.O_APPEND;
            } else {
                flags |= c.O_TRUNC;
            }
            const fd = c.open(cfile.ptr, flags, @as(c_uint, 0o644));
            if (fd < 0) {
                std.debug.print("zish: {s}: Cannot open file\n", .{file});
                std.process.exit(1);
            }
            posix.dup2(@intCast(fd), posix.STDOUT_FILENO) catch std.process.exit(1);
        }

        if (stdin_fd) |fd| posix.close(fd);
        if (stdout_fd) |fd| posix.close(fd);

        // Reset SIGINT to default in child via C API
        _ = c.signal(c.SIGINT, null);

        // execvp via libc - does not return on success
        const ret = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        _ = ret;
        std.debug.print("zish: {s}: command not found\n", .{cmd.args.items[0]});
        std.process.exit(127);
    }

    if (stdin_fd) |fd| posix.close(fd);
    if (stdout_fd) |fd| posix.close(fd);

    return pid;
}

/// Execute a single pipeline (commands connected by |)
pub fn executePipeline(
    alloc: std.mem.Allocator,
    pipeline: *std.ArrayList(Command),
    findBuiltinFn: *const fn ([]const u8) ?BuiltinFn,
) !i32 {
    if (pipeline.items.len == 0) return 0;

    // Expand globs before execution
    try parser.expandGlobs(alloc, pipeline);

    // Single command: run builtin in-process (no fork needed)
    if (pipeline.items.len == 1) {
        const cmd = &pipeline.items[0];
        if (cmd.args.items.len > 0) {
            if (findBuiltinFn(cmd.args.items[0])) |builtin_fn| {
                _ = builtin_fn(cmd.args.items);
                return 0;
            }
        }
    }

    var prev_read_fd: ?i32 = null;
    var pids: std.ArrayList(posix.pid_t) = .empty;
    defer pids.deinit(alloc);

    for (pipeline.items, 0..) |*cmd, i| {
        const is_last = (i == pipeline.items.len - 1);

        var write_fd: ?i32 = null;
        var read_fd: ?i32 = null;

        if (!is_last) {
            const pipe_fds = try posix.pipe();
            read_fd = pipe_fds[0];
            write_fd = pipe_fds[1];
        }

        // Check if this command is a builtin
        const is_builtin = if (cmd.args.items.len > 0)
            findBuiltinFn(cmd.args.items[0]) != null
        else
            false;

        if (is_builtin) {
            const pid = try executeBuiltinInPipeline(alloc, cmd, prev_read_fd, write_fd, findBuiltinFn);
            try pids.append(alloc, pid);
        } else {
            const pid = try executeExternal(alloc, cmd, prev_read_fd, write_fd);
            try pids.append(alloc, pid);
        }
        prev_read_fd = read_fd;
    }

    var exit_code: i32 = 0;
    for (pids.items) |pid| {
        const result = posix.waitpid(pid, 0);
        if (std.os.linux.W.IFEXITED(result.status)) {
            exit_code = @intCast(std.os.linux.W.EXITSTATUS(result.status));
        } else {
            exit_code = 128;
        }
    }

    return exit_code;
}

/// Fork a child that runs a builtin, with pipeline fd wiring.
/// Builtins use std.debug.print (stderr), so we dup stderr→stdout in the child.
fn executeBuiltinInPipeline(
    _: std.mem.Allocator,
    cmd: *const Command,
    stdin_fd: ?i32,
    stdout_fd: ?i32,
    findBuiltinFn: *const fn ([]const u8) ?BuiltinFn,
) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        // Child: wire up fds
        if (stdin_fd) |fd|
            posix.dup2(fd, posix.STDIN_FILENO) catch std.process.exit(1);
        if (stdout_fd) |fd|
            posix.dup2(fd, posix.STDOUT_FILENO) catch std.process.exit(1);

        // Builtins write to stderr (std.debug.print), redirect stderr→stdout
        posix.dup2(posix.STDOUT_FILENO, posix.STDERR_FILENO) catch std.process.exit(1);

        if (stdin_fd) |fd| posix.close(fd);
        if (stdout_fd) |fd| posix.close(fd);

        _ = c.signal(c.SIGINT, null);

        if (findBuiltinFn(cmd.args.items[0])) |builtin_fn| {
            _ = builtin_fn(cmd.args.items);
            std.process.exit(0);
        }
        std.process.exit(1);
    }

    if (stdin_fd) |fd| posix.close(fd);
    if (stdout_fd) |fd| posix.close(fd);

    return pid;
}

/// Execute a command list (pipelines connected by && / ||)
pub fn executeCommandList(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(parser.PipelineEntry),
    findBuiltinFn: *const fn ([]const u8) ?BuiltinFn,
) !i32 {
    var exit_code: i32 = 0;

    for (list.items, 0..) |*entry, i| {
        // Check connector from PREVIOUS entry to decide whether to run this one
        if (i > 0) {
            const prev_connector = list.items[i - 1].connector;
            switch (prev_connector) {
                .@"and" => {
                    if (exit_code != 0) continue; // skip if previous failed
                },
                .@"or" => {
                    if (exit_code == 0) continue; // skip if previous succeeded
                },
                .none => {},
            }
        }

        exit_code = try executePipeline(alloc, &entry.pipeline, findBuiltinFn);
    }

    return exit_code;
}
