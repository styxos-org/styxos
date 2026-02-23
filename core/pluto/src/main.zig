const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// ============================================================================
// Types
// ============================================================================

const CpuTimes = struct {
    user: u64,
    nice: u64,
    system: u64,
    idle: u64,
    iowait: u64,
    irq: u64,
    softirq: u64,
    total: u64,

    fn busy(self: CpuTimes) u64 {
        return self.total - self.idle - self.iowait;
    }
};

const CpuUsage = struct {
    user_pct: f64,
    system_pct: f64,
    iowait_pct: f64,
    idle_pct: f64,
};

const LoadAvg = struct {
    avg1: f64,
    avg5: f64,
    avg15: f64,
    running: u32,
    total: u32,
};

const NetStats = struct {
    iface: [32]u8,
    iface_len: usize,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_errors: u64,
    tx_errors: u64,

    fn ifaceName(self: *const NetStats) []const u8 {
        return self.iface[0..self.iface_len];
    }
};

const DiskIo = struct {
    device: [32]u8,
    device_len: usize,
    reads_completed: u64,
    reads_merged: u64,
    sectors_read: u64,
    time_reading_ms: u64,
    writes_completed: u64,
    writes_merged: u64,
    sectors_written: u64,
    time_writing_ms: u64,

    fn deviceName(self: *const DiskIo) []const u8 {
        return self.device[0..self.device_len];
    }
};

const DiskSpace = struct {
    mount: [128]u8,
    mount_len: usize,
    total_bytes: u64,
    free_bytes: u64,
    avail_bytes: u64,

    fn mountPoint(self: *const DiskSpace) []const u8 {
        return self.mount[0..self.mount_len];
    }

    fn usedPct(self: *const DiskSpace) f64 {
        if (self.total_bytes == 0) return 0;
        return @as(f64, @floatFromInt(self.total_bytes - self.free_bytes)) /
            @as(f64, @floatFromInt(self.total_bytes)) * 100.0;
    }
};

const MemInfo = struct {
    total_kb: u64,
    free_kb: u64,
    available_kb: u64,
    buffers_kb: u64,
    cached_kb: u64,
    swap_total_kb: u64,
    swap_free_kb: u64,
};

// ============================================================================
// /proc and /sys readers
// ============================================================================

fn readProcFile(path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();
    const n = try file.readAll(buf);
    return buf[0..n];
}

fn parseCpuTimes() !CpuTimes {
    var buf: [4096]u8 = undefined;
    const content = try readProcFile("/proc/stat", &buf);
    return parseCpuTimesFromContent(content);
}

fn parseCpuTimesFromContent(content: []const u8) !CpuTimes {
    // First line: "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first_line = lines.first();
    if (!std.mem.startsWith(u8, first_line, "cpu ")) return error.ParseError;

    var fields = std.mem.tokenizeScalar(u8, first_line, ' ');
    _ = fields.next(); // skip "cpu"

    const user = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const nice = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const system = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const idle = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const iowait = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const irq = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);
    const softirq = try std.fmt.parseInt(u64, fields.next() orelse return error.ParseError, 10);

    const total = user + nice + system + idle + iowait + irq + softirq;

    return .{
        .user = user,
        .nice = nice,
        .system = system,
        .idle = idle,
        .iowait = iowait,
        .irq = irq,
        .softirq = softirq,
        .total = total,
    };
}

fn computeCpuUsage(prev: CpuTimes, curr: CpuTimes) CpuUsage {
    const dt = curr.total - prev.total;
    if (dt == 0) return .{ .user_pct = 0, .system_pct = 0, .iowait_pct = 0, .idle_pct = 100 };

    const dtf: f64 = @floatFromInt(dt);
    return .{
        .user_pct = @as(f64, @floatFromInt((curr.user + curr.nice) - (prev.user + prev.nice))) / dtf * 100.0,
        .system_pct = @as(f64, @floatFromInt((curr.system + curr.irq + curr.softirq) - (prev.system + prev.irq + prev.softirq))) / dtf * 100.0,
        .iowait_pct = @as(f64, @floatFromInt(curr.iowait - prev.iowait)) / dtf * 100.0,
        .idle_pct = @as(f64, @floatFromInt(curr.idle - prev.idle)) / dtf * 100.0,
    };
}

fn parseLoadAvg() !LoadAvg {
    var buf: [256]u8 = undefined;
    const content = try readProcFile("/proc/loadavg", &buf);
    return parseLoadAvgFromContent(content);
}

fn parseLoadAvgFromContent(content: []const u8) !LoadAvg {
    // Format: "0.12 0.34 0.56 2/345 6789"
    var fields = std.mem.tokenizeScalar(u8, std.mem.trimRight(u8, content, "\n"), ' ');

    const avg1_str = fields.next() orelse return error.ParseError;
    const avg5_str = fields.next() orelse return error.ParseError;
    const avg15_str = fields.next() orelse return error.ParseError;
    const procs_str = fields.next() orelse return error.ParseError;

    // Parse "running/total"
    var procs_iter = std.mem.splitScalar(u8, procs_str, '/');
    const running_str = procs_iter.first();
    const total_str = procs_iter.next() orelse return error.ParseError;

    return .{
        .avg1 = try std.fmt.parseFloat(f64, avg1_str),
        .avg5 = try std.fmt.parseFloat(f64, avg5_str),
        .avg15 = try std.fmt.parseFloat(f64, avg15_str),
        .running = try std.fmt.parseInt(u32, running_str, 10),
        .total = try std.fmt.parseInt(u32, total_str, 10),
    };
}

fn parseNetStats(out: []NetStats) !usize {
    var buf: [8192]u8 = undefined;
    const content = try readProcFile("/proc/net/dev", &buf);
    return parseNetStatsFromContent(content, out);
}

fn parseNetStatsFromContent(content: []const u8, out: []NetStats) !usize {
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // skip header 1
    _ = lines.next(); // skip header 2

    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (count >= out.len) break;

        // Format: "  iface: rx_bytes rx_packets rx_errs rx_drop ... tx_bytes tx_packets tx_errs ..."
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface_raw = std.mem.trim(u8, line[0..colon_pos], " ");

        // Skip loopback
        if (std.mem.eql(u8, iface_raw, "lo")) continue;

        var entry = &out[count];
        const copy_len = @min(iface_raw.len, entry.iface.len);
        @memcpy(entry.iface[0..copy_len], iface_raw[0..copy_len]);
        entry.iface_len = copy_len;

        var fields = std.mem.tokenizeScalar(u8, line[colon_pos + 1 ..], ' ');
        entry.rx_bytes = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.rx_packets = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.rx_errors = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        _ = fields.next(); // rx_drop
        _ = fields.next(); // rx_fifo
        _ = fields.next(); // rx_frame
        _ = fields.next(); // rx_compressed
        _ = fields.next(); // rx_multicast
        entry.tx_bytes = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.tx_packets = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.tx_errors = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);

        count += 1;
    }

    return count;
}

fn parseDiskStats(out: []DiskIo) !usize {
    var buf: [8192]u8 = undefined;
    const content = try readProcFile("/proc/diskstats", &buf);
    return parseDiskStatsFromContent(content, out);
}

fn parseDiskStatsFromContent(content: []const u8, out: []DiskIo) !usize {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var count: usize = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (count >= out.len) break;

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next(); // major
        _ = fields.next(); // minor
        const dev_name = fields.next() orelse continue;

        // Skip partitions (only keep whole disks like sda, vda, nvme0n1)
        // Heuristic: skip if name ends with a digit and contains a 'p' or digit partition suffix
        if (isPartition(dev_name)) continue;

        var entry = &out[count];
        const copy_len = @min(dev_name.len, entry.device.len);
        @memcpy(entry.device[0..copy_len], dev_name[0..copy_len]);
        entry.device_len = copy_len;

        entry.reads_completed = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.reads_merged = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.sectors_read = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.time_reading_ms = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.writes_completed = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.writes_merged = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.sectors_written = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);
        entry.time_writing_ms = try std.fmt.parseInt(u64, fields.next() orelse continue, 10);

        count += 1;
    }

    return count;
}

fn isPartition(name: []const u8) bool {
    if (name.len == 0) return false;
    // "sda1", "vda1" -> partition; "sda", "vda" -> disk
    // "nvme0n1" -> disk; "nvme0n1p1" -> partition
    // "loop0" -> skip entirely
    if (std.mem.startsWith(u8, name, "loop")) return true;
    if (std.mem.startsWith(u8, name, "ram")) return true;
    if (std.mem.startsWith(u8, name, "dm-")) return false; // device mapper = keep

    // NVMe: nvme0n1 = disk, nvme0n1p1 = partition
    if (std.mem.startsWith(u8, name, "nvme")) {
        // Check if there's a 'p' followed by digits after 'n<digit>'
        if (std.mem.lastIndexOfScalar(u8, name, 'p')) |p_idx| {
            if (p_idx > 0 and std.ascii.isDigit(name[p_idx - 1])) {
                // Check chars after p are all digits
                for (name[p_idx + 1 ..]) |ch| {
                    if (!std.ascii.isDigit(ch)) return false;
                }
                return name.len > p_idx + 1;
            }
        }
        return false;
    }

    // sd*, vd*, hd*: partition if ends with digit
    const last = name[name.len - 1];
    return std.ascii.isDigit(last);
}

/// Use the C statvfs syscall to get filesystem space info.
/// We go through @cImport since Zig's std doesn't wrap statvfs.
const posix = @cImport({
    @cInclude("sys/statvfs.h");
});

fn getDiskSpaceC(mount_path: [*:0]const u8) !DiskSpace {
    var stat: posix.struct_statvfs = undefined;
    const ret = posix.statvfs(mount_path, &stat);
    if (ret != 0) return error.StatvfsFailed;

    const bsize: u64 = @intCast(stat.f_frsize);
    var result: DiskSpace = undefined;
    result.total_bytes = @as(u64, @intCast(stat.f_blocks)) * bsize;
    result.free_bytes = @as(u64, @intCast(stat.f_bfree)) * bsize;
    result.avail_bytes = @as(u64, @intCast(stat.f_bavail)) * bsize;
    result.mount_len = 0;
    return result;
}

fn parseMemInfo() !MemInfo {
    var buf: [4096]u8 = undefined;
    const content = try readProcFile("/proc/meminfo", &buf);
    return parseMemInfoFromContent(content);
}

fn parseMemInfoFromContent(content: []const u8) !MemInfo {
    var result: MemInfo = std.mem.zeroes(MemInfo);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon_pos], " ");
        const val_str = std.mem.trim(u8, line[colon_pos + 1 ..], " ");

        // Values are "12345 kB" – parse the number before " kB"
        var val_fields = std.mem.tokenizeScalar(u8, val_str, ' ');
        const num_str = val_fields.next() orelse continue;
        const val = std.fmt.parseInt(u64, num_str, 10) catch continue;

        if (std.mem.eql(u8, key, "MemTotal")) {
            result.total_kb = val;
        } else if (std.mem.eql(u8, key, "MemFree")) {
            result.free_kb = val;
        } else if (std.mem.eql(u8, key, "MemAvailable")) {
            result.available_kb = val;
        } else if (std.mem.eql(u8, key, "Buffers")) {
            result.buffers_kb = val;
        } else if (std.mem.eql(u8, key, "Cached")) {
            result.cached_kb = val;
        } else if (std.mem.eql(u8, key, "SwapTotal")) {
            result.swap_total_kb = val;
        } else if (std.mem.eql(u8, key, "SwapFree")) {
            result.swap_free_kb = val;
        }
    }

    return result;
}

// ============================================================================
// SQLite wrapper
// ============================================================================

const Db = struct {
    handle: *c.sqlite3,
    insert_stmt: *c.sqlite3_stmt,

    fn open(path: [*:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &handle) != c.SQLITE_OK) {
            return error.SqliteOpenFailed;
        }
        const db = handle.?;

        // WAL mode for concurrent read access while writing
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL", null, null, null);
        _ = c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL", null, null, null);

        // Create schema
        const schema =
            \\CREATE TABLE IF NOT EXISTS metrics (
            \\    ts INTEGER NOT NULL,
            \\    kind TEXT NOT NULL,
            \\    device TEXT NOT NULL DEFAULT '',
            \\    json TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_metrics_ts_kind ON metrics(ts, kind);
            \\CREATE INDEX IF NOT EXISTS idx_metrics_kind_device ON metrics(kind, device, ts);
        ;

        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(db, schema, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg) |msg| {
                std.debug.print("SQLite schema error: {s}\n", .{std.mem.span(msg)});
                c.sqlite3_free(msg);
            }
            return error.SqliteSchemaFailed;
        }

        // Prepare insert statement
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO metrics (ts, kind, device, json) VALUES (?, ?, ?, ?)";
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }

        return .{
            .handle = db,
            .insert_stmt = stmt.?,
        };
    }

    fn close(self: *Db) void {
        _ = c.sqlite3_finalize(self.insert_stmt);
        _ = c.sqlite3_close(self.handle);
    }

    fn beginTransaction(self: *Db) void {
        _ = c.sqlite3_exec(self.handle, "BEGIN", null, null, null);
    }

    fn commit(self: *Db) void {
        _ = c.sqlite3_exec(self.handle, "COMMIT", null, null, null);
    }

    fn insertMetric(self: *Db, ts: i64, kind: [*:0]const u8, device: [*:0]const u8, json: [*:0]const u8) !void {
        _ = c.sqlite3_reset(self.insert_stmt);
        _ = c.sqlite3_bind_int64(self.insert_stmt, 1, ts);
        _ = c.sqlite3_bind_text(self.insert_stmt, 2, kind, -1, null);
        _ = c.sqlite3_bind_text(self.insert_stmt, 3, device, -1, null);
        _ = c.sqlite3_bind_text(self.insert_stmt, 4, json, -1, null);

        if (c.sqlite3_step(self.insert_stmt) != c.SQLITE_DONE) {
            return error.SqliteInsertFailed;
        }
    }
};

// ============================================================================
// JSON formatting helpers (no allocator needed)
// ============================================================================

fn formatCpuJson(usage: CpuUsage, buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf,
        \\{{"user":{d:.2},"system":{d:.2},"iowait":{d:.2},"idle":{d:.2}}}
    , .{ usage.user_pct, usage.system_pct, usage.iowait_pct, usage.idle_pct }) catch return error.FormatError;
}

fn formatLoadJson(load: LoadAvg, buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf,
        \\{{"avg1":{d:.2},"avg5":{d:.2},"avg15":{d:.2},"running":{d},"total":{d}}}
    , .{ load.avg1, load.avg5, load.avg15, load.running, load.total }) catch return error.FormatError;
}

fn formatNetJson(stats: *const NetStats, prev: ?*const NetStats, interval_s: f64, buf: []u8) ![:0]const u8 {
    var rx_rate: f64 = 0;
    var tx_rate: f64 = 0;
    if (prev) |p| {
        rx_rate = @as(f64, @floatFromInt(stats.rx_bytes - p.rx_bytes)) / interval_s;
        tx_rate = @as(f64, @floatFromInt(stats.tx_bytes - p.tx_bytes)) / interval_s;
    }
    return std.fmt.bufPrintZ(buf,
        \\{{"rx_bytes":{d},"tx_bytes":{d},"rx_rate":{d:.0},"tx_rate":{d:.0},"rx_packets":{d},"tx_packets":{d},"rx_errors":{d},"tx_errors":{d}}}
    , .{
        stats.rx_bytes,  stats.tx_bytes,
        rx_rate,         tx_rate,
        stats.rx_packets, stats.tx_packets,
        stats.rx_errors, stats.tx_errors,
    }) catch return error.FormatError;
}

fn formatDiskIoJson(stats: *const DiskIo, prev: ?*const DiskIo, interval_s: f64, buf: []u8) ![:0]const u8 {
    var read_rate: f64 = 0;
    var write_rate: f64 = 0;
    if (prev) |p| {
        // sectors are 512 bytes
        read_rate = @as(f64, @floatFromInt(stats.sectors_read - p.sectors_read)) * 512.0 / interval_s;
        write_rate = @as(f64, @floatFromInt(stats.sectors_written - p.sectors_written)) * 512.0 / interval_s;
    }
    return std.fmt.bufPrintZ(buf,
        \\{{"reads":{d},"writes":{d},"read_bytes_s":{d:.0},"write_bytes_s":{d:.0},"read_ms":{d},"write_ms":{d}}}
    , .{
        stats.reads_completed,  stats.writes_completed,
        read_rate,              write_rate,
        stats.time_reading_ms, stats.time_writing_ms,
    }) catch return error.FormatError;
}

fn formatDiskSpaceJson(space: *const DiskSpace, buf: []u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf,
        \\{{"total":{d},"free":{d},"avail":{d},"used_pct":{d:.1}}}
    , .{ space.total_bytes, space.free_bytes, space.avail_bytes, space.usedPct() }) catch return error.FormatError;
}

fn formatMemJson(mem: MemInfo, buf: []u8) ![:0]const u8 {
    const used_kb = mem.total_kb - mem.available_kb;
    const used_pct = if (mem.total_kb > 0)
        @as(f64, @floatFromInt(used_kb)) / @as(f64, @floatFromInt(mem.total_kb)) * 100.0
    else
        0.0;
    return std.fmt.bufPrintZ(buf,
        \\{{"total_kb":{d},"available_kb":{d},"used_kb":{d},"used_pct":{d:.1},"buffers_kb":{d},"cached_kb":{d},"swap_total_kb":{d},"swap_free_kb":{d}}}
    , .{
        mem.total_kb,     mem.available_kb, used_kb,         used_pct,
        mem.buffers_kb,   mem.cached_kb,    mem.swap_total_kb, mem.swap_free_kb,
    }) catch return error.FormatError;
}

// ============================================================================
// Main loop
// ============================================================================

const Config = struct {
    db_path: [:0]const u8 = "/var/metrics.db",
    interval_s: u32 = 5,
    mounts: []const [:0]const u8 = &default_mounts,

    const default_mounts: [1][:0]const u8 = .{"/"};
};

fn parseArgs() Config {
    var config = Config{};
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                config.db_path = std.mem.sliceTo(val, 0);
            }
        } else if (std.mem.eql(u8, arg, "--interval")) {
            if (args.next()) |val| {
                config.interval_s = std.fmt.parseInt(u32, val, 10) catch 5;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help =
                \\sysmon - System metrics collector
                \\
                \\Usage: sysmon [OPTIONS]
                \\
                \\Options:
                \\  --db <path>       SQLite database path (default: /var/lib/sysmon/metrics.db)
                \\  --interval <sec>  Collection interval in seconds (default: 5)
                \\  -h, --help        Show this help
                \\
            ;
            std.debug.print("{s}", .{help});
            std.process.exit(0);
        }
    }

    return config;
}

pub fn main() !void {
    const config = parseArgs();

    // Stdout for log messages (Writergate: explicit buffer + flush)
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("sysmon starting – db={s} interval={d}s\n", .{ config.db_path, config.interval_s });
    try stdout.flush();

    // Open database
    var db = try Db.open(config.db_path.ptr);
    defer db.close();

    try stdout.print("database opened, schema ready\n", .{});
    try stdout.flush();

    // State for delta calculations
    var prev_cpu: ?CpuTimes = null;
    var prev_net: [16]NetStats = undefined;
    var prev_net_count: usize = 0;
    var prev_disk: [16]DiskIo = undefined;
    var prev_disk_count: usize = 0;

    var json_buf: [2048]u8 = undefined;
    const interval_ns: u64 = @as(u64, config.interval_s) * std.time.ns_per_s;
    const interval_f: f64 = @floatFromInt(config.interval_s);

    // Collection loop
    while (true) {
        const ts = std.time.timestamp();

        db.beginTransaction();

        // --- CPU ---
        if (parseCpuTimes()) |cpu_now| {
            if (prev_cpu) |prev| {
                const usage = computeCpuUsage(prev, cpu_now);
                if (formatCpuJson(usage, &json_buf)) |json| {
                    db.insertMetric(ts, "cpu", "", json) catch |err| {
                        try stdout.print("insert cpu error: {}\n", .{err});
                    };
                } else |_| {}
            }
            prev_cpu = cpu_now;
        } else |err| {
            try stdout.print("cpu parse error: {}\n", .{err});
        }

        // --- Load ---
        if (parseLoadAvg()) |load| {
            if (formatLoadJson(load, &json_buf)) |json| {
                db.insertMetric(ts, "load", "", json) catch |err| {
                    try stdout.print("insert load error: {}\n", .{err});
                };
            } else |_| {}
        } else |err| {
            try stdout.print("load parse error: {}\n", .{err});
        }

        // --- Memory ---
        if (parseMemInfo()) |mem| {
            if (formatMemJson(mem, &json_buf)) |json| {
                db.insertMetric(ts, "mem", "", json) catch |err| {
                    try stdout.print("insert mem error: {}\n", .{err});
                };
            } else |_| {}
        } else |err| {
            try stdout.print("mem parse error: {}\n", .{err});
        }

        // --- Network ---
        {
            var curr_net: [16]NetStats = undefined;
            if (parseNetStats(&curr_net)) |curr_count| {
                for (curr_net[0..curr_count]) |*net| {
                    // Find matching previous entry
                    const prev_entry = findPrevNet(prev_net[0..prev_net_count], net.ifaceName());
                    if (formatNetJson(net, prev_entry, interval_f, &json_buf)) |json| {
                        // We need a null-terminated device name for SQLite
                        var dev_buf: [33]u8 = undefined;
                        const dev_z = bufZ(&dev_buf, net.ifaceName());
                        db.insertMetric(ts, "net", dev_z, json) catch |err| {
                            try stdout.print("insert net error: {}\n", .{err});
                        };
                    } else |_| {}
                }
                @memcpy(prev_net[0..curr_count], curr_net[0..curr_count]);
                prev_net_count = curr_count;
            } else |err| {
                try stdout.print("net parse error: {}\n", .{err});
            }
        }

        // --- Disk I/O ---
        {
            var curr_disk: [16]DiskIo = undefined;
            if (parseDiskStats(&curr_disk)) |curr_count| {
                for (curr_disk[0..curr_count]) |*disk| {
                    const prev_entry = findPrevDisk(prev_disk[0..prev_disk_count], disk.deviceName());
                    if (formatDiskIoJson(disk, prev_entry, interval_f, &json_buf)) |json| {
                        var dev_buf: [33]u8 = undefined;
                        const dev_z = bufZ(&dev_buf, disk.deviceName());
                        db.insertMetric(ts, "diskio", dev_z, json) catch |err| {
                            try stdout.print("insert diskio error: {}\n", .{err});
                        };
                    } else |_| {}
                }
                @memcpy(prev_disk[0..curr_count], curr_disk[0..curr_count]);
                prev_disk_count = curr_count;
            } else |err| {
                try stdout.print("diskio parse error: {}\n", .{err});
            }
        }

        // --- Disk Space ---
        for (config.mounts) |mount| {
            if (getDiskSpaceC(mount.ptr)) |*space_ptr| {
                var space = space_ptr.*;
                const m = @as([]const u8, std.mem.sliceTo(mount, 0));
                const copy_len = @min(m.len, space.mount.len);
                @memcpy(space.mount[0..copy_len], m[0..copy_len]);
                space.mount_len = copy_len;

                if (formatDiskSpaceJson(&space, &json_buf)) |json| {
                    db.insertMetric(ts, "diskspace", mount, json) catch |err| {
                        try stdout.print("insert diskspace error: {}\n", .{err});
                    };
                } else |_| {}
            } else |err| {
                try stdout.print("diskspace error for {s}: {}\n", .{ mount, err });
            }
        }

        db.commit();

        try stdout.print("[{d}] tick – metrics collected\n", .{ts});
        try stdout.flush();

        // Sleep until next interval
        std.Thread.sleep(interval_ns);
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn findPrevNet(prev: []const NetStats, name: []const u8) ?*const NetStats {
    for (prev) |*entry| {
        if (std.mem.eql(u8, entry.ifaceName(), name)) return entry;
    }
    return null;
}

fn findPrevDisk(prev: []const DiskIo, name: []const u8) ?*const DiskIo {
    for (prev) |*entry| {
        if (std.mem.eql(u8, entry.deviceName(), name)) return entry;
    }
    return null;
}

/// Copy a slice into a fixed buffer and null-terminate it.
fn bufZ(buf: []u8, src: []const u8) [*:0]const u8 {
    const len = @min(src.len, buf.len - 1);
    @memcpy(buf[0..len], src[0..len]);
    buf[len] = 0;
    return @ptrCast(buf[0..len :0]);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseCpuTimes: basic /proc/stat" {
    const content =
        \\cpu  10132153 290696 3084719 46828483 16683 0 25195 0 0 0
        \\cpu0 1393280 32966 572056 13343292 6130 0 17875 0 0 0
    ;
    const cpu = try parseCpuTimesFromContent(content);
    try testing.expectEqual(@as(u64, 10132153), cpu.user);
    try testing.expectEqual(@as(u64, 290696), cpu.nice);
    try testing.expectEqual(@as(u64, 3084719), cpu.system);
    try testing.expectEqual(@as(u64, 46828483), cpu.idle);
    try testing.expectEqual(@as(u64, 16683), cpu.iowait);
    try testing.expectEqual(@as(u64, 0), cpu.irq);
    try testing.expectEqual(@as(u64, 25195), cpu.softirq);

    const expected_total: u64 = 10132153 + 290696 + 3084719 + 46828483 + 16683 + 0 + 25195;
    try testing.expectEqual(expected_total, cpu.total);
}

test "parseCpuTimes: reject invalid header" {
    const content = "wrong_header 123 456";
    try testing.expectError(error.ParseError, parseCpuTimesFromContent(content));
}

test "computeCpuUsage: 50% user, 25% system, 25% idle" {
    const prev = CpuTimes{
        .user = 100, .nice = 0, .system = 0, .idle = 100,
        .iowait = 0, .irq = 0, .softirq = 0, .total = 200,
    };
    const curr = CpuTimes{
        .user = 200, .nice = 0, .system = 50, .idle = 150,
        .iowait = 0, .irq = 0, .softirq = 0, .total = 400,
    };
    const usage = computeCpuUsage(prev, curr);
    try testing.expectApproxEqAbs(@as(f64, 50.0), usage.user_pct, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 25.0), usage.system_pct, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 25.0), usage.idle_pct, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0.0), usage.iowait_pct, 0.01);
}

test "computeCpuUsage: zero delta returns 100% idle" {
    const same = CpuTimes{
        .user = 100, .nice = 0, .system = 50, .idle = 50,
        .iowait = 0, .irq = 0, .softirq = 0, .total = 200,
    };
    const usage = computeCpuUsage(same, same);
    try testing.expectApproxEqAbs(@as(f64, 100.0), usage.idle_pct, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0.0), usage.user_pct, 0.01);
}

test "parseLoadAvg: standard format" {
    const content = "0.72 0.48 0.36 3/412 9876\n";
    const load = try parseLoadAvgFromContent(content);
    try testing.expectApproxEqAbs(@as(f64, 0.72), load.avg1, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.48), load.avg5, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.36), load.avg15, 0.001);
    try testing.expectEqual(@as(u32, 3), load.running);
    try testing.expectEqual(@as(u32, 412), load.total);
}

test "parseLoadAvg: high load values" {
    const content = "12.50 8.25 4.10 15/1024 31337\n";
    const load = try parseLoadAvgFromContent(content);
    try testing.expectApproxEqAbs(@as(f64, 12.50), load.avg1, 0.001);
    try testing.expectEqual(@as(u32, 15), load.running);
    try testing.expectEqual(@as(u32, 1024), load.total);
}

test "parseNetStats: multiple interfaces, skip lo" {
    const content =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo: 1234567   12345    0    0    0     0          0         0  1234567   12345    0    0    0     0       0          0
        \\  eth0: 9876543   54321   10    5    0     0          0         0  5432109   43210    2    0    0     0       0          0
        \\wlan0:  3456789   23456    0    0    0     0          0         0  2345678   12345    0    0    0     0       0          0
    ;
    var out: [16]NetStats = undefined;
    const count = try parseNetStatsFromContent(content, &out);
    try testing.expectEqual(@as(usize, 2), count); // lo skipped

    // eth0
    try testing.expectEqualStrings("eth0", out[0].ifaceName());
    try testing.expectEqual(@as(u64, 9876543), out[0].rx_bytes);
    try testing.expectEqual(@as(u64, 5432109), out[0].tx_bytes);
    try testing.expectEqual(@as(u64, 54321), out[0].rx_packets);
    try testing.expectEqual(@as(u64, 43210), out[0].tx_packets);
    try testing.expectEqual(@as(u64, 10), out[0].rx_errors);
    try testing.expectEqual(@as(u64, 2), out[0].tx_errors);

    // wlan0
    try testing.expectEqualStrings("wlan0", out[1].ifaceName());
    try testing.expectEqual(@as(u64, 3456789), out[1].rx_bytes);
}

test "parseDiskStats: filter partitions and loops" {
    const content =
        \\   8       0 sda 12345 1234 567890 12345 54321 4321 987654 54321 0 12345 66666
        \\   8       1 sda1 6789 567 234567 6789 23456 1234 456789 23456 0 6789 30245
        \\   7       0 loop0 100 0 200 10 0 0 0 0 0 10 10
        \\ 259       0 nvme0n1 99999 5000 888888 50000 77777 3000 666666 40000 0 30000 90000
        \\ 259       1 nvme0n1p1 44444 2000 333333 20000 33333 1000 222222 10000 0 15000 30000
        \\ 253       0 dm-0 55555 0 444444 25000 44444 0 333333 20000 0 20000 45000
    ;
    var out: [16]DiskIo = undefined;
    const count = try parseDiskStatsFromContent(content, &out);
    try testing.expectEqual(@as(usize, 3), count); // sda, nvme0n1, dm-0

    try testing.expectEqualStrings("sda", out[0].deviceName());
    try testing.expectEqual(@as(u64, 12345), out[0].reads_completed);
    try testing.expectEqual(@as(u64, 567890), out[0].sectors_read);

    try testing.expectEqualStrings("nvme0n1", out[1].deviceName());
    try testing.expectEqual(@as(u64, 99999), out[1].reads_completed);

    try testing.expectEqualStrings("dm-0", out[2].deviceName());
    try testing.expectEqual(@as(u64, 55555), out[2].reads_completed);
}

test "isPartition: classification" {
    // Whole disks
    try testing.expect(!isPartition("sda"));
    try testing.expect(!isPartition("vda"));
    try testing.expect(!isPartition("nvme0n1"));
    try testing.expect(!isPartition("dm-0"));
    try testing.expect(!isPartition("dm-3"));

    // Partitions
    try testing.expect(isPartition("sda1"));
    try testing.expect(isPartition("sda12"));
    try testing.expect(isPartition("vda1"));
    try testing.expect(isPartition("nvme0n1p1"));
    try testing.expect(isPartition("nvme0n1p2"));

    // Skip
    try testing.expect(isPartition("loop0"));
    try testing.expect(isPartition("loop1"));
    try testing.expect(isPartition("ram0"));
}

test "parseMemInfo: standard format" {
    const content =
        \\MemTotal:       16384000 kB
        \\MemFree:         2048000 kB
        \\MemAvailable:    8192000 kB
        \\Buffers:          512000 kB
        \\Cached:          4096000 kB
        \\SwapCached:        12345 kB
        \\Active:          6000000 kB
        \\Inactive:        3000000 kB
        \\SwapTotal:       2097152 kB
        \\SwapFree:        1048576 kB
    ;
    const mem = try parseMemInfoFromContent(content);
    try testing.expectEqual(@as(u64, 16384000), mem.total_kb);
    try testing.expectEqual(@as(u64, 2048000), mem.free_kb);
    try testing.expectEqual(@as(u64, 8192000), mem.available_kb);
    try testing.expectEqual(@as(u64, 512000), mem.buffers_kb);
    try testing.expectEqual(@as(u64, 4096000), mem.cached_kb);
    try testing.expectEqual(@as(u64, 2097152), mem.swap_total_kb);
    try testing.expectEqual(@as(u64, 1048576), mem.swap_free_kb);
}

test "formatCpuJson: valid output" {
    const usage = CpuUsage{ .user_pct = 25.5, .system_pct = 10.3, .iowait_pct = 2.1, .idle_pct = 62.1 };
    var buf: [512]u8 = undefined;
    const json = try formatCpuJson(usage, &buf);
    // Verify it contains the key fields
    try testing.expect(std.mem.indexOf(u8, json, "\"user\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"system\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"idle\":") != null);
}

test "formatLoadJson: valid output" {
    const load = LoadAvg{ .avg1 = 1.5, .avg5 = 0.8, .avg15 = 0.3, .running = 4, .total = 300 };
    var buf: [512]u8 = undefined;
    const json = try formatLoadJson(load, &buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"avg1\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"running\":4") != null);
}

test "formatMemJson: used_pct calculation" {
    const mem = MemInfo{
        .total_kb = 16000000,
        .free_kb = 2000000,
        .available_kb = 8000000,
        .buffers_kb = 500000,
        .cached_kb = 4000000,
        .swap_total_kb = 2000000,
        .swap_free_kb = 1000000,
    };
    var buf: [1024]u8 = undefined;
    const json = try formatMemJson(mem, &buf);
    // used_pct = (16M - 8M) / 16M * 100 = 50.0
    try testing.expect(std.mem.indexOf(u8, json, "\"used_pct\":50.0") != null);
}

test "formatNetJson: rate calculation with previous sample" {
    const prev = NetStats{
        .iface = [_]u8{0} ** 32,
        .iface_len = 4,
        .rx_bytes = 1000000,
        .tx_bytes = 500000,
        .rx_packets = 1000,
        .tx_packets = 500,
        .rx_errors = 0,
        .tx_errors = 0,
    };
    var curr = prev;
    curr.rx_bytes = 1050000; // +50000 in 5s = 10000 bytes/s
    curr.tx_bytes = 525000; // +25000 in 5s = 5000 bytes/s

    var buf: [1024]u8 = undefined;
    const json = try formatNetJson(&curr, &prev, 5.0, &buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"rx_rate\":10000") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tx_rate\":5000") != null);
}

test "formatDiskIoJson: rate calculation" {
    const prev = DiskIo{
        .device = [_]u8{0} ** 32,
        .device_len = 3,
        .reads_completed = 1000,
        .reads_merged = 100,
        .sectors_read = 20000, // 20000 * 512 = ~10MB
        .time_reading_ms = 5000,
        .writes_completed = 500,
        .writes_merged = 50,
        .sectors_written = 10000,
        .time_writing_ms = 3000,
    };
    var curr = prev;
    curr.sectors_read = 22000; // +2000 sectors in 5s = 2000*512/5 = 204800 bytes/s
    curr.sectors_written = 11000;

    var buf: [1024]u8 = undefined;
    const json = try formatDiskIoJson(&curr, &prev, 5.0, &buf);
    try testing.expect(std.mem.indexOf(u8, json, "\"read_bytes_s\":204800") != null);
}

test "DiskSpace.usedPct: calculation" {
    var space: DiskSpace = undefined;
    space.total_bytes = 1000000000; // 1GB
    space.free_bytes = 300000000; // 300MB
    space.avail_bytes = 250000000;
    space.mount_len = 1;
    space.mount[0] = '/';

    // used = 700M / 1G = 70%
    try testing.expectApproxEqAbs(@as(f64, 70.0), space.usedPct(), 0.01);
}

test "DiskSpace.usedPct: zero total" {
    var space: DiskSpace = undefined;
    space.total_bytes = 0;
    space.free_bytes = 0;
    space.avail_bytes = 0;
    space.mount_len = 0;
    try testing.expectApproxEqAbs(@as(f64, 0.0), space.usedPct(), 0.01);
}

test "bufZ: null termination" {
    var buf: [8]u8 = undefined;
    const result = bufZ(&buf, "hello");
    try testing.expectEqualStrings("hello", std.mem.span(result));
}

test "bufZ: truncation on overflow" {
    var buf: [4]u8 = undefined;
    const result = bufZ(&buf, "longstring");
    try testing.expectEqual(@as(usize, 3), std.mem.span(result).len);
}

test "Db: integration – open, insert, verify" {
    const db_path = "test_metrics.db";

    // Open (creates file if not exists, re-runs schema with IF NOT EXISTS)
    var db = try Db.open(db_path);
    defer db.close();

    const ts = std.time.timestamp();

    db.beginTransaction();

    // Insert synthetic CPU metric
    const cpu_json = "{\"user\":25.50,\"system\":10.30,\"iowait\":2.10,\"idle\":62.10}";
    try db.insertMetric(ts, "cpu", "", cpu_json);

    // Insert synthetic load metric
    const load_json = "{\"avg1\":1.50,\"avg5\":0.80,\"avg15\":0.30,\"running\":4,\"total\":300}";
    try db.insertMetric(ts, "load", "", load_json);

    // Insert synthetic net metric with device
    const net_json = "{\"rx_bytes\":9876543,\"tx_bytes\":5432109,\"rx_rate\":10000,\"tx_rate\":5000}";
    try db.insertMetric(ts, "net", "eth0", net_json);

    // Insert synthetic mem metric
    const mem_json = "{\"total_kb\":16000000,\"available_kb\":8000000,\"used_pct\":50.0}";
    try db.insertMetric(ts, "mem", "", mem_json);

    db.commit();

    // Verify: count rows via a separate query
    var count_stmt: ?*c.sqlite3_stmt = null;
    const count_sql = "SELECT COUNT(*) FROM metrics WHERE ts = ?";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.handle, count_sql, -1, &count_stmt, null));
    defer _ = c.sqlite3_finalize(count_stmt);

    _ = c.sqlite3_bind_int64(count_stmt.?, 1, ts);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(count_stmt.?));
    const row_count = c.sqlite3_column_int(count_stmt.?, 0);
    try testing.expectEqual(@as(c_int, 4), row_count);

    // Verify: check a specific row
    var select_stmt: ?*c.sqlite3_stmt = null;
    const select_sql = "SELECT json FROM metrics WHERE ts = ? AND kind = 'net' AND device = 'eth0'";
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db.handle, select_sql, -1, &select_stmt, null));
    defer _ = c.sqlite3_finalize(select_stmt);

    _ = c.sqlite3_bind_int64(select_stmt.?, 1, ts);
    try testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(select_stmt.?));

    const json_ptr = c.sqlite3_column_text(select_stmt.?, 0);
    const json_result = std.mem.span(json_ptr);
    try testing.expect(std.mem.indexOf(u8, json_result, "\"rx_rate\":10000") != null);
}
