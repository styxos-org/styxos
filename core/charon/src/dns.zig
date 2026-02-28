const std = @import("std");
const mem = std.mem;

// DNS Record Types
pub const RecordType = enum(u16) {
    A = 1,
    AAAA = 28,
    CNAME = 5,
    TXT = 16,
    NS = 2,
    SOA = 6,
    MX = 15,
    PTR = 12,
    _,

    pub fn fromString(s: []const u8) ?RecordType {
        if (mem.eql(u8, s, "A")) return .A;
        if (mem.eql(u8, s, "AAAA")) return .AAAA;
        if (mem.eql(u8, s, "CNAME")) return .CNAME;
        if (mem.eql(u8, s, "TXT")) return .TXT;
        if (mem.eql(u8, s, "NS")) return .NS;
        if (mem.eql(u8, s, "SOA")) return .SOA;
        if (mem.eql(u8, s, "MX")) return .MX;
        if (mem.eql(u8, s, "PTR")) return .PTR;
        return null;
    }

    pub fn toString(self: RecordType) []const u8 {
        return switch (self) {
            .A => "A",
            .AAAA => "AAAA",
            .CNAME => "CNAME",
            .TXT => "TXT",
            .NS => "NS",
            .SOA => "SOA",
            .MX => "MX",
            .PTR => "PTR",
            _ => "UNKNOWN",
        };
    }
};

pub const Class = enum(u16) {
    IN = 1,
    _,
};

pub const ResponseCode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_failure = 2,
    name_error = 3, // NXDOMAIN
    not_implemented = 4,
    refused = 5,
    _,
};

pub const Header = struct {
    id: u16,
    flags: u16,
    qd_count: u16,
    an_count: u16,
    ns_count: u16,
    ar_count: u16,

    pub fn isQuery(self: Header) bool {
        return (self.flags & 0x8000) == 0;
    }

    pub fn makeResponse(self: Header, rcode: ResponseCode, an_count: u16) Header {
        // QR=1, AA=1, RD from query, RA=1
        const rd: u16 = self.flags & 0x0100;
        const flags: u16 = 0x8000 | 0x0400 | rd | 0x0080 | @as(u16, @intFromEnum(rcode));
        return .{
            .id = self.id,
            .flags = flags,
            .qd_count = self.qd_count,
            .an_count = an_count,
            .ns_count = 0,
            .ar_count = 0,
        };
    }

    pub fn makeForwardResponse(self: Header) Header {
        // For forwarded responses: keep original ID, set QR=1, RA=1
        return .{
            .id = self.id,
            .flags = self.flags | 0x8000 | 0x0080,
            .qd_count = self.qd_count,
            .an_count = self.an_count,
            .ns_count = self.ns_count,
            .ar_count = self.ar_count,
        };
    }

    pub fn serialize(self: Header, buf: []u8) !usize {
        if (buf.len < 12) return error.BufferTooSmall;
        writeU16(buf[0..2], self.id);
        writeU16(buf[2..4], self.flags);
        writeU16(buf[4..6], self.qd_count);
        writeU16(buf[6..8], self.an_count);
        writeU16(buf[8..10], self.ns_count);
        writeU16(buf[10..12], self.ar_count);
        return 12;
    }

    pub fn parse(buf: []const u8) !Header {
        if (buf.len < 12) return error.BufferTooSmall;
        return .{
            .id = readU16(buf[0..2]),
            .flags = readU16(buf[2..4]),
            .qd_count = readU16(buf[4..6]),
            .an_count = readU16(buf[6..8]),
            .ns_count = readU16(buf[8..10]),
            .ar_count = readU16(buf[10..12]),
        };
    }
};

pub const Question = struct {
    name: [256]u8,
    name_len: usize,
    qtype: u16,
    qclass: u16,

    pub fn getName(self: *const Question) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn parse(buf: []const u8, offset: usize) !struct { question: Question, new_offset: usize } {
        var q = Question{
            .name = undefined,
            .name_len = 0,
            .qtype = 0,
            .qclass = 0,
        };

        var pos = offset;
        var name_pos: usize = 0;

        // Parse domain name labels
        while (pos < buf.len) {
            const label_len = buf[pos];
            if (label_len == 0) {
                pos += 1;
                break;
            }
            if ((label_len & 0xC0) == 0xC0) {
                // Compression pointer
                if (pos + 1 >= buf.len) return error.InvalidPacket;
                const ptr = (@as(u16, label_len & 0x3F) << 8) | @as(u16, buf[pos + 1]);
                // Follow pointer (simplified, no recursion protection)
                var ptr_pos: usize = @intCast(ptr);
                while (ptr_pos < buf.len) {
                    const plen = buf[ptr_pos];
                    if (plen == 0) break;
                    if (name_pos > 0) {
                        q.name[name_pos] = '.';
                        name_pos += 1;
                    }
                    ptr_pos += 1;
                    if (ptr_pos + plen > buf.len or name_pos + plen > q.name.len) return error.InvalidPacket;
                    @memcpy(q.name[name_pos .. name_pos + plen], buf[ptr_pos .. ptr_pos + plen]);
                    name_pos += plen;
                    ptr_pos += plen;
                }
                pos += 2;
                break;
            }

            pos += 1;
            if (name_pos > 0) {
                q.name[name_pos] = '.';
                name_pos += 1;
            }
            if (pos + label_len > buf.len or name_pos + label_len > q.name.len) return error.InvalidPacket;
            @memcpy(q.name[name_pos .. name_pos + label_len], buf[pos .. pos + label_len]);
            name_pos += label_len;
            pos += label_len;
        }

        q.name_len = name_pos;

        if (pos + 4 > buf.len) return error.InvalidPacket;
        q.qtype = readU16(buf[pos .. pos + 2]);
        q.qclass = readU16(buf[pos + 2 .. pos + 4]);
        pos += 4;

        return .{ .question = q, .new_offset = pos };
    }

    pub fn serialize(self: *const Question, buf: []u8, offset: usize) !usize {
        var pos = offset;
        const name = self.getName();

        // Encode domain name as labels
        var start: usize = 0;
        for (name, 0..) |ch, i| {
            if (ch == '.') {
                const label_len = i - start;
                if (pos + 1 + label_len > buf.len) return error.BufferTooSmall;
                buf[pos] = @intCast(label_len);
                pos += 1;
                @memcpy(buf[pos .. pos + label_len], name[start..i]);
                pos += label_len;
                start = i + 1;
            }
        }
        // Last label
        const last_len = name.len - start;
        if (last_len > 0) {
            if (pos + 1 + last_len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(last_len);
            pos += 1;
            @memcpy(buf[pos .. pos + last_len], name[start..]);
            pos += last_len;
        }
        // Null terminator
        if (pos + 5 > buf.len) return error.BufferTooSmall;
        buf[pos] = 0;
        pos += 1;

        writeU16(buf[pos .. pos + 2], self.qtype);
        writeU16(buf[pos + 2 .. pos + 4], self.qclass);
        pos += 4;

        return pos;
    }
};

// Serialize a DNS resource record (answer section)
pub fn serializeAnswer(buf: []u8, offset: usize, name: []const u8, rtype: RecordType, ttl: u32, rdata: []const u8) !usize {
    var pos = offset;

    // Encode name
    var start: usize = 0;
    for (name, 0..) |ch, i| {
        if (ch == '.') {
            const label_len = i - start;
            if (pos + 1 + label_len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(buf[pos .. pos + label_len], name[start..i]);
            pos += label_len;
            start = i + 1;
        }
    }
    const last_len = name.len - start;
    if (last_len > 0) {
        if (pos + 1 + last_len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(last_len);
        pos += 1;
        @memcpy(buf[pos .. pos + last_len], name[start..]);
        pos += last_len;
    }
    if (pos + 1 > buf.len) return error.BufferTooSmall;
    buf[pos] = 0;
    pos += 1;

    // TYPE, CLASS, TTL, RDLENGTH
    if (pos + 10 + rdata.len > buf.len) return error.BufferTooSmall;
    writeU16(buf[pos .. pos + 2], @intFromEnum(rtype));
    writeU16(buf[pos + 2 .. pos + 4], 1); // IN class
    writeU32(buf[pos + 4 .. pos + 8], ttl);
    writeU16(buf[pos + 8 .. pos + 10], @intCast(rdata.len));
    pos += 10;

    @memcpy(buf[pos .. pos + rdata.len], rdata);
    pos += rdata.len;

    return pos;
}

/// Parse an IPv4 address string to 4 bytes
pub fn parseIPv4(s: []const u8) ![4]u8 {
    var result: [4]u8 = undefined;
    var octet: usize = 0;
    var val: u16 = 0;
    var digits: u8 = 0;

    for (s) |ch| {
        if (ch == '.') {
            if (digits == 0 or octet >= 3) return error.InvalidAddress;
            if (val > 255) return error.InvalidAddress;
            result[octet] = @intCast(val);
            octet += 1;
            val = 0;
            digits = 0;
        } else if (ch >= '0' and ch <= '9') {
            val = val * 10 + (ch - '0');
            digits += 1;
        } else {
            return error.InvalidAddress;
        }
    }
    if (digits == 0 or octet != 3 or val > 255) return error.InvalidAddress;
    result[3] = @intCast(val);
    return result;
}

/// Parse an IPv6 address string to 16 bytes (simplified)
pub fn parseIPv6(s: []const u8) ![16]u8 {
    var result: [16]u8 = [_]u8{0} ** 16;
    var groups: [8]u16 = [_]u16{0} ** 8;
    var group_count: usize = 0;
    var double_colon_pos: ?usize = null;
    var current: u16 = 0;
    var has_digits = false;
    var i: usize = 0;

    while (i < s.len) {
        const ch = s[i];
        if (ch == ':') {
            if (i + 1 < s.len and s[i + 1] == ':') {
                if (double_colon_pos != null) return error.InvalidAddress;
                if (has_digits) {
                    groups[group_count] = current;
                    group_count += 1;
                }
                double_colon_pos = group_count;
                current = 0;
                has_digits = false;
                i += 2;
                continue;
            }
            if (!has_digits) return error.InvalidAddress;
            groups[group_count] = current;
            group_count += 1;
            current = 0;
            has_digits = false;
            i += 1;
            continue;
        }
        const digit: u16 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'f')
            ch - 'a' + 10
        else if (ch >= 'A' and ch <= 'F')
            ch - 'A' + 10
        else
            return error.InvalidAddress;
        current = current * 16 + digit;
        has_digits = true;
        i += 1;
    }

    if (has_digits) {
        groups[group_count] = current;
        group_count += 1;
    }

    // Expand :: 
    if (double_colon_pos) |dcp| {
        const tail_len = group_count - dcp;
        const shift = 8 - group_count;
        // Move tail groups to the end
        var j: usize = 0;
        while (j < tail_len) : (j += 1) {
            groups[7 - j] = groups[group_count - 1 - j];
        }
        // Zero fill the gap
        j = dcp;
        while (j < dcp + shift) : (j += 1) {
            groups[j] = 0;
        }
    } else if (group_count != 8) {
        return error.InvalidAddress;
    }

    for (groups, 0..) |g, gi| {
        result[gi * 2] = @intCast(g >> 8);
        result[gi * 2 + 1] = @intCast(g & 0xFF);
    }

    return result;
}

/// Encode a domain name to DNS wire format for CNAME rdata
pub fn encodeDomainName(buf: []u8, name: []const u8) !usize {
    var pos: usize = 0;
    var start: usize = 0;

    for (name, 0..) |ch, i| {
        if (ch == '.') {
            const label_len = i - start;
            if (pos + 1 + label_len > buf.len) return error.BufferTooSmall;
            buf[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(buf[pos .. pos + label_len], name[start..i]);
            pos += label_len;
            start = i + 1;
        }
    }
    const last_len = name.len - start;
    if (last_len > 0) {
        if (pos + 1 + last_len > buf.len) return error.BufferTooSmall;
        buf[pos] = @intCast(last_len);
        pos += 1;
        @memcpy(buf[pos .. pos + last_len], name[start..]);
        pos += last_len;
    }
    if (pos + 1 > buf.len) return error.BufferTooSmall;
    buf[pos] = 0;
    pos += 1;

    return pos;
}

// Helpers
pub fn readU16(buf: []const u8) u16 {
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

pub fn writeU16(buf: []u8, val: u16) void {
    buf[0] = @intCast(val >> 8);
    buf[1] = @intCast(val & 0xFF);
}

pub fn writeU32(buf: []u8, val: u32) void {
    buf[0] = @intCast((val >> 24) & 0xFF);
    buf[1] = @intCast((val >> 16) & 0xFF);
    buf[2] = @intCast((val >> 8) & 0xFF);
    buf[3] = @intCast(val & 0xFF);
}
