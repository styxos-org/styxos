const std = @import("std");
const posix = std.posix;

// Callback signature for TAB completion.
// The shell provides this function. It receives the current line and returns 
// an allocated string with the completion (or null if no completion found).
pub const CompletionCallback = *const fn (allocator: std.mem.Allocator, line: []const u8) ?[]const u8;

// Encapsulation of history logic (ready for SQLite later)
pub const History = struct {
    entries: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .entries = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *History, line: []const u8) !void {
        if (line.len == 0) return;
        const copy = try self.allocator.dupe(u8, line);
        try self.entries.append(self.allocator, copy);
    }

    pub fn get(self: *const History, index: usize) ?[]const u8 {
        if (index < self.entries.items.len) {
            return self.entries.items[index];
        }
        return null;
    }

    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }
};

pub fn prompt(
    allocator: std.mem.Allocator, 
    history: *History, 
    prompt_text: []const u8,
    completion_cb: ?CompletionCallback
) !?[]const u8 {
    const stdin_fd = posix.STDIN_FILENO;

    // Dedicated buffer for editor output
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Switch terminal to raw mode
    const orig_termios = try posix.tcgetattr(stdin_fd);
    var raw = orig_termios;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    
    // Ensure the terminal is restored after the prompt returns
    defer posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var cursor: usize = 0;
    
    var history_idx: usize = history.count();

    while (true) {
        try stdout.print("\r\x1b[2K{s}{s}", .{ prompt_text, buf[0..len] });
        
        if (cursor < len) {
            try stdout.print("\x1b[{d}D", .{len - cursor});
        }
        try stdout.flush();

        var c: [1]u8 = undefined;
        const bytes_read = try posix.read(stdin_fd, &c);
        if (bytes_read == 0) continue;

        switch (c[0]) {
            1 => cursor = 0,   // Ctrl-A: Start of line
            3 => { // Ctrl-C: Interrupt
                try stdout.print("^C\r\n", .{});
                try stdout.flush();
                return error.Interrupt;
            },
            4 => { // Ctrl-D: EOF or Delete
                if (len == 0) {
                    try stdout.print("\r\n", .{});
                    try stdout.flush();
                    return null; // Signal EOF
                } else if (cursor < len) {
                    len -= 1;
                    std.mem.copyForwards(u8, buf[cursor..len], buf[cursor + 1 .. len + 1]);
                }
            },
            5 => cursor = len, // Ctrl-E: End of line
            9 => { // TAB: Auto-completion callback
                if (completion_cb) |cb| {
                    if (cb(allocator, buf[0..len])) |completed_line| {
                        defer allocator.free(completed_line);
                        
                        const new_len = @min(completed_line.len, buf.len);
                        @memcpy(buf[0..new_len], completed_line[0..new_len]);
                        len = new_len;
                        cursor = len;
                    }
                }
            },
            11 => len = cursor, // Ctrl-K: Delete from cursor to end of line
            12 => try stdout.print("\x1b[H\x1b[2J", .{}), // Ctrl-L: Clear screen
            21 => { // Ctrl-U: Delete from start of line to cursor
                if (cursor > 0) {
                    const remain = len - cursor;
                    if (remain > 0) {
                        std.mem.copyForwards(u8, buf[0..remain], buf[cursor..len]);
                    }
                    len -= cursor;
                    cursor = 0;
                }
            },
            23 => { // Ctrl-W: Delete previous word
                if (cursor > 0) {
                    var new_cursor = cursor;
                    while (new_cursor > 0 and buf[new_cursor - 1] == ' ') new_cursor -= 1;
                    while (new_cursor > 0 and buf[new_cursor - 1] != ' ') new_cursor -= 1;
                    
                    const remain = len - cursor;
                    if (remain > 0) {
                        std.mem.copyForwards(u8, buf[new_cursor .. new_cursor + remain], buf[cursor .. len]);
                    }
                    len -= (cursor - new_cursor);
                    cursor = new_cursor;
                }
            },
            '\r', '\n' => { // Enter
                try stdout.print("\r\n", .{});
                try stdout.flush();
                try history.add(buf[0..len]);
                // Create a heap copy and return it to the caller (the shell)
                return try allocator.dupe(u8, buf[0..len]);
            },
            127, 8 => { // Backspace
                if (cursor > 0) {
                    cursor -= 1;
                    len -= 1;
                    if (cursor < len) {
                        std.mem.copyForwards(u8, buf[cursor..len], buf[cursor + 1 .. len + 1]);
                    }
                }
            },
            '\x1b' => { // Escape sequences
                var seq: [3]u8 = undefined;
                const seq_read = try posix.read(stdin_fd, seq[0..2]);
                if (seq_read > 0) {
                    if (seq[0] == '[' and seq_read == 2) {
                        switch (seq[1]) {
                            'A' => { // Up arrow
                                if (history_idx > 0) {
                                    history_idx -= 1;
                                    if (history.get(history_idx)) |line| {
                                        @memcpy(buf[0..line.len], line);
                                        len = line.len;
                                        cursor = len;
                                    }
                                }
                            },
                            'B' => { // Down arrow
                                if (history_idx < history.count()) {
                                    history_idx += 1;
                                    if (history_idx == history.count()) {
                                        len = 0;
                                        cursor = 0;
                                    } else if (history.get(history_idx)) |line| {
                                        @memcpy(buf[0..line.len], line);
                                        len = line.len;
                                        cursor = len;
                                    }
                                }
                            },
                            'C' => { if (cursor < len) cursor += 1; }, // Right arrow
                            'D' => { if (cursor > 0) cursor -= 1; },   // Left arrow
                            '3' => { // Delete key
                                const tilde_read = try posix.read(stdin_fd, seq[2..3]);
                                if (tilde_read == 1 and seq[2] == '~') {
                                    if (cursor < len) {
                                        len -= 1;
                                        std.mem.copyForwards(u8, buf[cursor..len], buf[cursor + 1 .. len + 1]);
                                    }
                                }
                            },
                            else => {},
                        }
                    } else if (seq[0] == '.') { // Esc-. or Alt-.
                        if (history.count() > 0) {
                            if (history.get(history.count() - 1)) |last_cmd| {
                                var end: usize = last_cmd.len;
                                // Ignore trailing spaces
                                while (end > 0 and last_cmd[end - 1] == ' ') end -= 1;
                                
                                var start: usize = end;
                                // Find start of the last word
                                while (start > 0 and last_cmd[start - 1] != ' ') start -= 1;
                                
                                if (end > start) {
                                    const param = last_cmd[start..end];
                                    if (len + param.len <= buf.len) {
                                        // Shift right and insert param
                                        std.mem.copyBackwards(u8, buf[cursor + param.len .. len + param.len], buf[cursor..len]);
                                        @memcpy(buf[cursor .. cursor + param.len], param);
                                        cursor += param.len;
                                        len += param.len;
                                    }
                                }
                            }
                        }
                    }
                }
            },
            else => {
                // Insert regular printable characters
                if (c[0] >= 32 and c[0] < 127 and len < buf.len) {
                    if (cursor < len) {
                        std.mem.copyBackwards(u8, buf[cursor + 1 .. len + 1], buf[cursor..len]);
                    }
                    buf[cursor] = c[0];
                    cursor += 1;
                    len += 1;
                }
            }
        }
    }
}

// --- ZISH SHELL LAYER (Example Implementation) ---

// Dummy completion function provided by the shell.
fn dummyCompletion(allocator: std.mem.Allocator, line: []const u8) ?[]const u8 {
    // Basic example: complete "ec" or "ech" to "echo "
    if (std.mem.eql(u8, line, "e") or std.mem.eql(u8, line, "ec") or std.mem.eql(u8, line, "ech")) {
        return allocator.dupe(u8, "echo ") catch null;
    }
    // Complete "gi" to "git "
    if (std.mem.eql(u8, line, "g") or std.mem.eql(u8, line, "gi")) {
        return allocator.dupe(u8, "git ") catch null;
    }
    // Return null if no match found (linecrash ignores it and does nothing)
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // The outer shell loop
    while (true) {
        // Pass the dummyCompletion callback to linecrash
        const line_opt = prompt(allocator, &history, "zish> ", dummyCompletion) catch |err| {
            if (err == error.Interrupt) {
                continue; // Just restart the prompt loop on Ctrl-C
            }
            return err;
        };

        if (line_opt) |line| {
            defer allocator.free(line); // Free memory allocated by linecrash
            
            if (std.mem.eql(u8, line, "exit")) {
                break;
            }
            
            if (line.len > 0) {
                try stdout.print("Executing command: {s}\n", .{line});
                try stdout.flush();
            }
        } else {
            // Received Ctrl-D (EOF)
            try stdout.print("Exiting Zish...\n", .{});
            try stdout.flush();
            break;
        }
    }
}
