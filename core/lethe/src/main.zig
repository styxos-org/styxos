const std = @import("std");
const posix = std.posix;

// --- I18n Strings (ändern für andere Sprachen) ---
const strings = struct {
    const mode_normal = "NORMAL";
    const mode_insert = "INSERT";
    const label_line = "Zeile";
    const label_col = "Spalte";
    const hint_keys = "i=Einfügen q=Beenden w=Speichern";
    const msg_saved = "Gespeichert!";
    const msg_saved_as = "Gespeichert als {s}";
    const msg_save_error = "Fehler beim Speichern!";
    const msg_unsaved = "Ungespeicherte Änderungen! w=Speichern, dann q";
    const msg_usage = "Usage: lethe <datei>";
    const empty_line_marker = "~";
    const help = [_][]const u8{
        "i/a/A  Einfügen: vor Cursor / nach Cursor / Zeilenende",
        "o/O    Neue Zeile: darunter / darüber",
        "dd     Zeile löschen    d$  Bis Zeilenende löschen",
        "cw     Wort ersetzen    x   Zeichen löschen",
        "u      Rückgängig       hjkl Bewegen",
        "0/$    Zeilenanfang/-ende",
        "w      Speichern        q   Beenden",
        "?      Hilfe ein/aus    ESC Normal-Modus",
    };
};

// --- Editierbare Zeile ---
const EditLine = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn fromSlice(allocator: std.mem.Allocator, slice: []const u8) !EditLine {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try buf.appendSlice(allocator, slice);
        return .{ .buf = buf };
    }

    fn items(self: *const EditLine) []const u8 {
        return self.buf.items;
    }

    fn len(self: *const EditLine) usize {
        return self.buf.items.len;
    }

    fn insertChar(self: *EditLine, allocator: std.mem.Allocator, pos: usize, ch: u8) !void {
        try self.buf.insert(allocator, pos, ch);
    }

    fn deleteChar(self: *EditLine, pos: usize) void {
        if (pos < self.buf.items.len) {
            _ = self.buf.orderedRemove(pos);
        }
    }

    fn backspace(self: *EditLine, pos: usize) bool {
        if (pos > 0 and pos <= self.buf.items.len) {
            _ = self.buf.orderedRemove(pos - 1);
            return true;
        }
        return false;
    }

    fn wordEnd(self: *const EditLine, start: usize) usize {
        const s = self.buf.items;
        if (start >= s.len) return s.len;
        var pos = start;
        // Whitespace überspringen
        while (pos < s.len and s[pos] == ' ') : (pos += 1) {}
        // Wort überspringen
        while (pos < s.len and s[pos] != ' ') : (pos += 1) {}
        return pos;
    }

    fn truncateFrom(self: *EditLine, pos: usize) void {
        if (pos < self.buf.items.len) {
            self.buf.shrinkRetainingCapacity(pos);
        }
    }

    fn deleteRange(self: *EditLine, from: usize, to: usize) void {
        if (from >= to or from >= self.buf.items.len) return;
        const end = @min(to, self.buf.items.len);
        const tail_len = self.buf.items.len - end;
        if (tail_len > 0) {
            std.mem.copyForwards(u8, self.buf.items[from..], self.buf.items[end..][0..tail_len]);
        }
        self.buf.shrinkRetainingCapacity(from + tail_len);
    }
};

const EditLines = std.ArrayListUnmanaged(EditLine);

// --- Undo (Snapshot-basiert, vi-Semantik) ---
const Snapshot = struct {
    lines: []const EditLine,
    cursor_y: usize,
    cursor_x: usize,
};
const UndoStack = std.ArrayListUnmanaged(Snapshot);

fn cloneLines(allocator: std.mem.Allocator, lines: EditLines) ![]const EditLine {
    const copy = try allocator.alloc(EditLine, lines.items.len);
    for (lines.items, 0..) |line, i| {
        copy[i] = try EditLine.fromSlice(allocator, line.items());
    }
    return copy;
}

fn pushUndo(undo: *UndoStack, allocator: std.mem.Allocator, lines: EditLines, cy: usize, cx: usize) !void {
    try undo.append(allocator, .{
        .lines = try cloneLines(allocator, lines),
        .cursor_y = cy,
        .cursor_x = cx,
    });
}

fn popUndo(undo: *UndoStack, allocator: std.mem.Allocator, lines: *EditLines, cy: *usize, cx: *usize) bool {
    if (undo.items.len == 0) return false;
    const snap = undo.pop().?;
    lines.items.len = 0;
    lines.appendSlice(allocator, snap.lines) catch return false;
    cy.* = snap.cursor_y;
    cx.* = snap.cursor_x;
    return true;
}
// --- Datei einlesen ---
fn readFile(allocator: std.mem.Allocator, path: []const u8) !EditLines {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);

    var lines: EditLines = .empty;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        try lines.append(allocator, try EditLine.fromSlice(allocator, line));
    }
    // Trailing empty line entfernen
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len() == 0) {
        _ = lines.pop();
    }
    // Mindestens eine Zeile
    if (lines.items.len == 0) {
        try lines.append(allocator, .{});
    }
    return lines;
}

// --- Datei speichern (VMS-style Versionierung) ---
// datei.txt     = Original (unverändert)
// datei.txt.1   = erster Save
// datei.txt.2   = zweiter Save
// höchste Nummer = neueste Version
fn findNextVersion(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var version: usize = 1;
    while (version < 9999) : (version += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, version });
        std.fs.cwd().access(candidate, .{}) catch {
            // Datei existiert nicht -> diese Nummer nehmen
            return candidate;
        };
    }
    return error.TooManyVersions;
}

fn saveFile(lines: EditLines, path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // Nächste freie Versionsnummer finden
    const versioned_path = try findNextVersion(path, allocator);

    // Neue Version schreiben
    const file = try std.fs.cwd().createFile(versioned_path, .{});
    defer file.close();

    for (lines.items, 0..) |line, i| {
        try file.writeAll(line.items());
        if (i + 1 < lines.items.len) {
            try file.writeAll("\n");
        }
    }
    try file.writeAll("\n");
    try file.sync();

    return versioned_path;
}

// --- Terminal Raw Mode ---
const RawTerm = struct {
    orig: posix.termios,

    fn enter() !RawTerm {
        const orig = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = orig;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;

        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .orig = orig };
    }

    fn leave(self: *RawTerm) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
    }
};

// --- Input ---
const Key = union(enum) {
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    char: u8,
    enter,
    backspace,
    delete,
    escape,
    none,
};

fn readKey() !Key {
    var buf: [3]u8 = undefined;
    const n = try posix.read(posix.STDIN_FILENO, &buf);
    if (n == 0) return .none;

    if (n == 1) {
        return switch (buf[0]) {
            0x1b => .escape,
            0x0d => .enter,
            0x7f => .backspace,
            else => .{ .char = buf[0] },
        };
    }
    if (n == 3 and buf[0] == 0x1b and buf[1] == '[') {
        return switch (buf[2]) {
            'A' => .arrow_up,
            'B' => .arrow_down,
            'C' => .arrow_right,
            'D' => .arrow_left,
            '3' => .delete, // Delete key (teilweise)
            else => .none,
        };
    }
    return .none;
}

// --- Terminal Size ---
fn getTermSize() !struct { rows: u16, cols: u16 } {
    var ws: posix.winsize = undefined;
    const rc = std.os.linux.ioctl(posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0) return .{ .rows = ws.row, .cols = ws.col };
    return .{ .rows = 24, .cols = 80 };
}

// --- Modus ---
const Mode = enum { normal, insert };

// --- Gutter (Zeilennummern) ---
fn gutterWidth(total_lines: usize) usize {
    // Mindestens 3 Stellen + 1 Leerzeichen
    var digits: usize = 1;
    var n = total_lines;
    while (n >= 10) : (n /= 10) {
        digits += 1;
    }
    return @max(digits, 3) + 1; // +1 für Leerzeichen nach der Nummer
}

// Finde Umbruchpositionen für Word-Wrap.
// Gibt die Start-Offsets jeder visuellen Zeile zurück.
// Bricht bei Leerzeichen oder nach '-' um, Fallback auf harten Umbruch.
fn wrapPositions(line: []const u8, text_width: usize, out: []usize) usize {
    if (line.len == 0) {
        out[0] = 0;
        return 1;
    }
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        if (count >= out.len) break;
        out[count] = pos;
        count += 1;

        if (pos + text_width >= line.len) break; // Rest passt

        // Suche letzten Umbruchpunkt im Fenster
        var break_at: ?usize = null;
        var i: usize = pos;
        while (i < pos + text_width and i < line.len) : (i += 1) {
            if (line[i] == ' ') {
                break_at = i; // Umbruch VOR dem Leerzeichen (Leerzeichen am Zeilenende)
            } else if (line[i] == '-' and i + 1 < line.len and i > pos) {
                break_at = i + 1; // Umbruch NACH dem Bindestrich
            }
        }

        if (break_at) |bp| {
            // Leerzeichen überspringen beim nächsten Zeilenstart
            pos = bp;
            if (pos < line.len and line[pos] == ' ') pos += 1;
        } else {
            // Kein Umbruchpunkt gefunden: harter Umbruch
            pos += text_width;
        }
    }
    return count;
}

fn screenLinesForLine(line: []const u8, text_width: usize) usize {
    var buf: [256]usize = undefined;
    return wrapPositions(line, text_width, &buf);
}

// Berechne die Bildschirmzeile und Spalte für eine Cursor-Position
fn cursorToScreen(cursor_y: usize, cursor_x: usize, lines: EditLines, text_width: usize, scroll_row: usize) struct { row: usize, col: usize } {
    var screen_row: usize = 0;
    var wp_buf: [256]usize = undefined;
    for (0..cursor_y) |i| {
        screen_row += screenLinesForLine(lines.items[i].items(), text_width);
    }
    // Finde in welcher Wrap-Zeile der Cursor liegt
    const wp_count = wrapPositions(lines.items[cursor_y].items(), text_width, &wp_buf);
    var wrap_line: usize = 0;
    for (0..wp_count) |w| {
        if (wp_buf[w] <= cursor_x) {
            wrap_line = w;
        } else {
            break;
        }
    }
    screen_row += wrap_line;
    const screen_col = cursor_x - wp_buf[wrap_line];
    return .{ .row = screen_row -| scroll_row, .col = screen_col };
}

// Berechne scroll_row so dass cursor sichtbar ist
fn adjustScroll(cursor_y: usize, cursor_x: usize, lines: EditLines, text_width: usize, visible_rows: usize, current_scroll: usize) usize {
    var screen_row: usize = 0;
    var wp_buf: [256]usize = undefined;
    for (0..cursor_y) |i| {
        screen_row += screenLinesForLine(lines.items[i].items(), text_width);
    }
    const wp_count = wrapPositions(lines.items[cursor_y].items(), text_width, &wp_buf);
    var wrap_line: usize = 0;
    for (0..wp_count) |w| {
        if (wp_buf[w] <= cursor_x) wrap_line = w else break;
    }
    const cursor_screen = screen_row + wrap_line;

    var scroll = current_scroll;
    if (cursor_screen < scroll) {
        scroll = cursor_screen;
    }
    if (cursor_screen >= scroll + visible_rows) {
        scroll = cursor_screen - visible_rows + 1;
    }
    return scroll;
}

// --- Render ---
fn render(stdout: *std.Io.Writer, lines: EditLines, cursor_y: usize, cursor_x: usize, scroll_row: usize, mode: Mode, message: []const u8, pending_op: u8, show_help: bool) !void {
    const size = try getTermSize();
    const help_lines = strings.help.len;
    const help_overhead: usize = if (show_help) help_lines + 1 else 0; // +1 für Trennlinie
    const visible_rows: usize = if (size.rows > 1 + help_overhead) size.rows - 1 - help_overhead else 1;
    const total = lines.items.len;
    const gw = gutterWidth(total);
    const text_width: usize = if (size.cols > gw) size.cols - gw else 1;

    try stdout.writeAll("\x1b[H\x1b[2J");

    // Welche Zeile/Wrap-Offset entspricht scroll_row?
    var file_line: usize = 0;
    var accumulated: usize = 0;
    while (file_line < total) {
        const sl = screenLinesForLine(lines.items[file_line].items(), text_width);
        if (accumulated + sl > scroll_row) break;
        accumulated += sl;
        file_line += 1;
    }
    var wrap_offset: usize = scroll_row - accumulated;

    var rows_drawn: usize = 0;
    var wp_buf: [256]usize = undefined;

    while (rows_drawn < visible_rows) {
        if (file_line >= total) {
            try stdout.print("\x1b[2m{s}\x1b[0m", .{strings.empty_line_marker});
            try stdout.writeAll("\r\n");
            rows_drawn += 1;
            continue;
        }

        const line = lines.items[file_line].items();
        const wp_count = wrapPositions(line, text_width, &wp_buf);

        var wrap: usize = wrap_offset;
        while (wrap < wp_count and rows_drawn < visible_rows) {
            if (wrap == 0) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{file_line + 1}) catch "?";
                try stdout.writeAll("\x1b[2m");
                const pad = if (gw - 1 > num_str.len) gw - 1 - num_str.len else 0;
                for (0..pad) |_| try stdout.writeAll(" ");
                try stdout.writeAll(num_str);
                try stdout.writeAll(" \x1b[0m");
            } else {
                for (0..gw) |_| try stdout.writeAll(" ");
            }

            const start = wp_buf[wrap];
            const end = if (wrap + 1 < wp_count) wp_buf[wrap + 1] else line.len;
            // Trailing space am Umbruch nicht anzeigen
            var display_end = end;
            if (wrap + 1 < wp_count and display_end > start and line[display_end - 1] == ' ') {
                display_end -= 1;
            }
            if (start < line.len) {
                try stdout.writeAll(line[start..@min(display_end, line.len)]);
            }
            try stdout.writeAll("\r\n");
            rows_drawn += 1;
            wrap += 1;
        }

        file_line += 1;
        wrap_offset = 0;
    }

    // Hilfe über der Statusbar
    if (show_help) {
        const sep_row = size.rows - help_lines - 1;
        // Durchgehende Trennlinie
        try stdout.print("\x1b[{d};1H\x1b[2m", .{sep_row});
        for (0..size.cols) |_| try stdout.writeAll("─");
        try stdout.writeAll("\x1b[0m");
        // Hilfetext
        for (strings.help, 0..) |hline, hi| {
            try stdout.print("\x1b[{d};1H\x1b[2m{s}\x1b[0m\x1b[K", .{ sep_row + 1 + hi, hline });
        }
    }

    // Statusbar
    const mode_str: []const u8 = switch (mode) {
        .normal => strings.mode_normal,
        .insert => strings.mode_insert,
    };

    if (message.len > 0) {
        try stdout.print("\x1b[{d};1H\x1b[2m {s}  {s}\x1b[0m\x1b[K", .{
            size.rows, mode_str, message,
        });
    } else if (pending_op != 0) {
        try stdout.print("\x1b[{d};1H\x1b[2m {s}  {s} {d}/{d}  {s} {d}  |  {c}… \x1b[0m\x1b[K", .{
            size.rows, mode_str, strings.label_line, cursor_y + 1, total, strings.label_col, cursor_x + 1, pending_op,
        });
    } else {
        try stdout.print("\x1b[{d};1H\x1b[2m {s}  {s} {d}/{d}  {s} {d}  |  {s} \x1b[0m\x1b[K", .{
            size.rows, mode_str, strings.label_line, cursor_y + 1, total, strings.label_col, cursor_x + 1, strings.hint_keys,
        });
    }

    // Cursor positionieren (mit Wrapping + Gutter-Offset)
    const cpos = cursorToScreen(cursor_y, cursor_x, lines, text_width, scroll_row);
    try stdout.print("\x1b[{d};{d}H", .{ cpos.row + 1, cpos.col + gw + 1 });
}

// --- Squash: höchste Version wird zum Original, Rest wird gelöscht ---
fn squash(path: []const u8, allocator: std.mem.Allocator) !void {
    var highest: usize = 0;

    // Höchste vorhandene Versionsnummer finden
    var v: usize = 1;
    while (v < 10000) : (v += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, v });
        std.fs.cwd().access(candidate, .{}) catch break;
        highest = v;
    }

    if (highest == 0) {
        std.debug.print("No versions found for {s}\n", .{path});
        return;
    }

    const newest = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, highest });

    // Alle älteren Versionen löschen (inkl. Original)
    std.fs.cwd().deleteFile(path) catch {};
    var d: usize = 1;
    while (d < highest) : (d += 1) {
        const old = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, d });
        std.fs.cwd().deleteFile(old) catch {};
    }

    // Höchste Version zum Original umbenennen
    try std.fs.cwd().rename(newest, path);
    std.debug.print("{s} -> {s} ({d} version(s) removed)\n", .{ newest, path, highest - 1 });
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| {
        return path[pos + 1 ..];
    }
    return path;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    // Squash-Modus: wenn als "squash" aufgerufen (Symlink)
    const prog = baseName(args[0]);
    if (std.mem.eql(u8, prog, "squash")) {
        if (args.len < 2) {
            std.debug.print("Usage: squash <datei>\n", .{});
            return;
        }
        try squash(args[1], allocator);
        return;
    }

    if (args.len < 2) {
        std.debug.print("{s}\n", .{strings.msg_usage});
        return;
    }

    const filepath = args[1];
    var lines = try readFile(allocator, filepath);

    var raw = try RawTerm.enter();
    defer raw.leave();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    try stdout.writeAll("\x1b[?1049h\x1b[?25h");
    try stdout.flush();

    defer {
        stdout.writeAll("\x1b[?1049l") catch {};
        stdout.flush() catch {};
    }

    var cursor_y: usize = 0;
    var cursor_x: usize = 0;
    var scroll_y: usize = 0;
    var mode: Mode = .normal;
    var dirty: bool = false;
    var message: []const u8 = "";
    var pending_op: u8 = 0;
    var show_help: bool = false;
    var undo: UndoStack = .empty; // für dd, d$, cw etc.

    while (true) {
        try render(stdout, lines, cursor_y, cursor_x, scroll_y, mode, message, pending_op, show_help);
        try stdout.flush();
        message = "";

        const key = try readKey();

        switch (mode) {
            // ===== NORMAL MODE =====
            .normal => switch (key) {
                .char => |ch| {
                    // Operator-Pending: zweiter Tastendruck
                    if (pending_op != 0) {
                        switch (pending_op) {
                            'd' => switch (ch) {
                                'd' => {
                                    try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                                    if (lines.items.len > 1) {
                                        _ = lines.orderedRemove(cursor_y);
                                        if (cursor_y >= lines.items.len) cursor_y = lines.items.len - 1;
                                    } else {
                                        lines.items[0].buf.shrinkRetainingCapacity(0);
                                        cursor_x = 0;
                                    }
                                    dirty = true;
                                },
                                '$' => {
                                    try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                                    lines.items[cursor_y].truncateFrom(cursor_x);
                                    dirty = true;
                                },
                                else => {},
                            },
                            'c' => switch (ch) {
                                'w' => {
                                    try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                                    const we = lines.items[cursor_y].wordEnd(cursor_x);
                                    lines.items[cursor_y].deleteRange(cursor_x, we);
                                    mode = .insert;
                                    dirty = true;
                                },
                                else => {},
                            },
                            else => {},
                        }
                        pending_op = 0;
                        continue;
                    }

                    switch (ch) {
                        'q' => {
                            if (dirty) {
                                message = strings.msg_unsaved;
                                continue;
                            }
                            break;
                        },
                        'i' => {
                            try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                            mode = .insert;
                        },
                        'a' => {
                            try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                            const ll = lines.items[cursor_y].len();
                            if (ll > 0) cursor_x += 1;
                            mode = .insert;
                        },
                        'A' => {
                            try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                            cursor_x = lines.items[cursor_y].len();
                            mode = .insert;
                        },
                        'o' => {
                            try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                            try lines.insert(allocator, cursor_y + 1, .{});
                            cursor_y += 1;
                            cursor_x = 0;
                            mode = .insert;
                            dirty = true;
                        },
                        'O' => {
                            try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                            try lines.insert(allocator, cursor_y, .{});
                            cursor_x = 0;
                            mode = .insert;
                            dirty = true;
                        },
                        'x' => {
                            const ll = lines.items[cursor_y].len();
                            if (ll > 0) {
                                try pushUndo(&undo, allocator, lines, cursor_y, cursor_x);
                                lines.items[cursor_y].deleteChar(cursor_x);
                                dirty = true;
                            }
                        },
                        'u' => {
                            if (popUndo(&undo, allocator, &lines, &cursor_y, &cursor_x)) {
                                dirty = true;
                                message = "Undo";
                            }
                        },
                        'd', 'c' => {
                            pending_op = ch;
                            continue;
                        },
                        'w' => {
                            const saved_path = saveFile(lines, filepath, allocator) catch {
                                message = strings.msg_save_error;
                                continue;
                            };
                            dirty = false;
                            message = std.fmt.allocPrint(allocator, strings.msg_saved_as, .{saved_path}) catch strings.msg_saved;
                        },
                        // vi-Bewegungen
                        'h' => {
                            if (cursor_x > 0) cursor_x -= 1;
                        },
                        'j' => {
                            if (cursor_y + 1 < lines.items.len) cursor_y += 1;
                        },
                        'k' => {
                            if (cursor_y > 0) cursor_y -= 1;
                        },
                        'l' => {
                            cursor_x += 1;
                        },
                        '0' => cursor_x = 0,
                        '$' => {
                            const ll = lines.items[cursor_y].len();
                            cursor_x = if (ll > 0) ll - 1 else 0;
                        },
                        '?' => show_help = !show_help,
                        else => {},
                    }
                },
                .arrow_up => {
                    if (cursor_y > 0) cursor_y -= 1;
                },
                .arrow_down => {
                    if (cursor_y + 1 < lines.items.len) cursor_y += 1;
                },
                .arrow_left => {
                    if (cursor_x > 0) cursor_x -= 1;
                },
                .arrow_right => {
                    cursor_x += 1;
                },
                else => {
                    pending_op = 0;
                },
            },

            // ===== INSERT MODE =====
            .insert => switch (key) {
                .escape => {
                    mode = .normal;
                    // Cursor ggf. zurücksetzen (vi-like)
                    if (cursor_x > 0) {
                        const ll = lines.items[cursor_y].len();
                        if (cursor_x >= ll and ll > 0) cursor_x = ll - 1;
                    }
                },
                .char => |ch| {
                    if (ch >= 32 and ch < 127) { // druckbare Zeichen
                        try lines.items[cursor_y].insertChar(allocator, cursor_x, ch);
                        cursor_x += 1;
                        dirty = true;
                    }
                },
                .enter => {
                    // Zeile splitten
                    const current = &lines.items[cursor_y];
                    const rest = current.buf.items[cursor_x..];

                    // Neue Zeile aus dem Rest erzeugen und einfügen
                    try lines.insert(allocator, cursor_y + 1, try EditLine.fromSlice(allocator, rest));

                    // Aktuelle Zeile abschneiden
                    current.buf.shrinkRetainingCapacity(cursor_x);

                    cursor_y += 1;
                    cursor_x = 0;
                    dirty = true;
                },
                .backspace => {
                    if (cursor_x > 0) {
                        // Zeichen löschen
                        if (lines.items[cursor_y].backspace(cursor_x)) {
                            cursor_x -= 1;
                            dirty = true;
                        }
                    } else if (cursor_y > 0) {
                        // Zeile mit vorheriger zusammenführen
                        const prev_len = lines.items[cursor_y - 1].len();
                        try lines.items[cursor_y - 1].buf.appendSlice(allocator, lines.items[cursor_y].items());
                        _ = lines.orderedRemove(cursor_y);
                        cursor_y -= 1;
                        cursor_x = prev_len;
                        dirty = true;
                    }
                },
                .delete => {
                    const ll = lines.items[cursor_y].len();
                    if (cursor_x < ll) {
                        lines.items[cursor_y].deleteChar(cursor_x);
                        dirty = true;
                    } else if (cursor_y + 1 < lines.items.len) {
                        // Nächste Zeile anhängen
                        try lines.items[cursor_y].buf.appendSlice(allocator, lines.items[cursor_y + 1].items());
                        _ = lines.orderedRemove(cursor_y + 1);
                        dirty = true;
                    }
                },
                .arrow_up => {
                    if (cursor_y > 0) cursor_y -= 1;
                },
                .arrow_down => {
                    if (cursor_y + 1 < lines.items.len) cursor_y += 1;
                },
                .arrow_left => {
                    if (cursor_x > 0) cursor_x -= 1;
                },
                .arrow_right => {
                    cursor_x += 1;
                },
                else => {},
            },
        }

        // Cursor-X an Zeilenlänge klemmen
        if (lines.items.len > 0) {
            const line_len = lines.items[cursor_y].len();
            if (mode == .normal) {
                // Normal mode: Cursor maximal auf letztes Zeichen
                if (line_len > 0) {
                    if (cursor_x >= line_len) cursor_x = line_len - 1;
                } else {
                    cursor_x = 0;
                }
            } else {
                // Insert mode: Cursor darf hinter letztes Zeichen
                if (cursor_x > line_len) cursor_x = line_len;
            }
        }

        // Scrolling (wrapping-aware)
        const vis = try getTermSize();
        const help_oh: usize = if (show_help) strings.help.len + 1 else 0;
        const vrows: usize = if (vis.rows > 1 + help_oh) vis.rows - 1 - help_oh else 1;
        const gw = gutterWidth(lines.items.len);
        const tw: usize = if (vis.cols > gw) vis.cols - gw else 1;
        scroll_y = adjustScroll(cursor_y, cursor_x, lines, tw, vrows, scroll_y);
    }
}
