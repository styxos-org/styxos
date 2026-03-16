const std = @import("std");
const lz4 = @import("lz4.zig");
const fs = std.fs;
const mem = std.mem;

// ============================================================================
// .lz Container Format
//
//   Offset  Size  Description
//   0       4     Magic: 0x4C, 0x5A, 0x34, 0x21  ("LZ4!")
//   4       8     Original size (little-endian u64)
//   12      8     Compressed size (little-endian u64)
//   20      N     Compressed data (N = compressed size)
//
// Total header: 20 bytes
// ============================================================================

const MAGIC = [4]u8{ 0x4C, 0x5A, 0x34, 0x21 }; // "LZ4!"
const HEADER_SIZE = 20;

const Command = enum { pack, unpack };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or args.len > 4) {
        usage(args[0]);
        std.process.exit(1);
    }

    const cmd: Command = if (mem.eql(u8, args[1], "pack"))
        .pack
    else if (mem.eql(u8, args[1], "unpack"))
        .unpack
    else {
        usage(args[0]);
        std.process.exit(1);
    };

    const input_path = args[2];

    switch (cmd) {
        .pack => {
            const default_name = if (args.len == 4) null else try defaultPackName(allocator, input_path);
            defer if (default_name) |n| allocator.free(n);
            const output_path = default_name orelse args[3];
            try packFile(allocator, input_path, output_path);
        },
        .unpack => {
            const default_name = if (args.len == 4) null else try defaultUnpackName(allocator, input_path);
            defer if (default_name) |n| allocator.free(n);
            const output_path = default_name orelse args[3];
            try unpackFile(allocator, input_path, output_path);
        },
    }
}

fn packFile(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const src = try readFileAlloc(allocator, input_path);
    defer allocator.free(src);

    const bound = lz4.compressBound(src.len);
    const comp_buf = try allocator.alloc(u8, bound);
    defer allocator.free(comp_buf);

    const comp_len = try lz4.compress(src, comp_buf);

    const ratio: f64 = if (src.len > 0)
        @as(f64, @floatFromInt(comp_len)) / @as(f64, @floatFromInt(src.len)) * 100.0
    else
        0.0;

    // write .lz file
    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    var out_w = out_file.writer(&.{});
    const writer = &out_w.interface;

    try writer.writeAll(&MAGIC);
    try writer.writeInt(u64, @intCast(src.len), .little);
    try writer.writeInt(u64, @intCast(comp_len), .little);
    try writer.writeAll(comp_buf[0..comp_len]);

    var stdout_w = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_w.interface;
    try stdout.print("{s} → {s}  ({d} → {d} bytes, {d:.1}%)\n", .{
        input_path, output_path, src.len, comp_len + HEADER_SIZE, ratio,
    });
}

fn unpackFile(allocator: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    const raw = try readFileAlloc(allocator, input_path);
    defer allocator.free(raw);

    if (raw.len < HEADER_SIZE) {
        fatal("file too small — not a valid .lz archive");
    }
    if (!mem.eql(u8, raw[0..4], &MAGIC)) {
        fatal("bad magic — not a valid .lz archive");
    }

    const orig_len: usize = @intCast(mem.readInt(u64, raw[4..12], .little));
    const comp_len: usize = @intCast(mem.readInt(u64, raw[12..20], .little));

    if (raw.len < HEADER_SIZE + comp_len) {
        fatal("truncated archive");
    }

    const comp_data = raw[HEADER_SIZE .. HEADER_SIZE + comp_len];

    const out_buf = try allocator.alloc(u8, orig_len);
    defer allocator.free(out_buf);

    lz4.decompress(comp_data, out_buf, orig_len) catch |err| {
        var stderr_w = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_w.interface;
        stderr.print("decompression failed: {}\n", .{err}) catch {};
        std.process.exit(1);
    };

    const out_file = try fs.cwd().createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(out_buf);

    var stdout_w = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_w.interface;
    try stdout.print("{s} → {s}  ({d} bytes)\n", .{ input_path, output_path, orig_len });
}

// ── helpers ──

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = fs.cwd().openFile(path, .{}) catch |err| {
        var stderr_w = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_w.interface;
        stderr.print("cannot open '{s}': {}\n", .{ path, err }) catch {};
        std.process.exit(1);
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 1 << 30); // max 1 GiB
}

fn defaultPackName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}.lz", .{path});
}

fn defaultUnpackName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (mem.endsWith(u8, path, ".lz")) {
        return try allocator.dupe(u8, path[0 .. path.len - 3]);
    }
    return try std.fmt.allocPrint(allocator, "{s}.orig", .{path});
}

fn usage(prog: []const u8) void {
    var stderr_w = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_w.interface;
    stderr.print(
        \\usage: {s} pack   <file> [output.lz]
        \\       {s} unpack <file.lz> [output]
        \\
        \\Compresses or decompresses a single file using LZ4.
        \\Original files are never modified or deleted.
        \\
    , .{ prog, prog }) catch {};
}

fn fatal(msg: []const u8) noreturn {
    var stderr_w = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_w.interface;
    stderr.print("error: {s}\n", .{msg}) catch {};
    std.process.exit(1);
}
