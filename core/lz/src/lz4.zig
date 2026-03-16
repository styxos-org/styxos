const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

// ============================================================================
// LZ4 Block Format Codec
//
// Token byte:  [literal_len:4][match_len:4]
// If literal_len == 15 → continuation bytes (each 255 means +255, first <255 terminates)
// Then: literal_len bytes of literal data
// Then: 2 bytes little-endian match offset (only if match_len field > 0 or token != pure-literal)
// If match_len + 4 >= 19 (i.e. match_len field == 15) → continuation bytes for match length
//
// Minimum match length = 4.  Match offset is backwards from current output position.
// ============================================================================

const HASH_LOG = 16;
const HASH_SIZE = 1 << HASH_LOG;
const MIN_MATCH = 4;
const ML_BITS = 4;
const ML_MASK = (1 << ML_BITS) - 1; // 15
const RUN_BITS = 4;
const RUN_MASK = (1 << RUN_BITS) - 1; // 15
const LAST_LITERALS = 5; // safety margin: last 5 bytes are always literals
const MF_LIMIT = 12; // minimum input size for match finding

/// Compress `src` into caller-provided `dst`.  Returns the number of bytes written.
/// `dst` must be large enough — use `compressBound` to size it.
pub fn compress(src: []const u8, dst: []u8) !usize {
    if (src.len == 0) return 0;
    if (src.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var hash_table: [HASH_SIZE]u32 = undefined;
    @memset(&hash_table, 0);

    var ip: usize = 0; // input pointer
    var op: usize = 0; // output pointer
    var anchor: usize = 0; // start of next literal run

    const mf_limit = if (src.len > MF_LIMIT) src.len - MF_LIMIT else 0;

    ip += 1; // first byte is never a match target

    while (ip < mf_limit) {
        // ── find match ──
        const h = hash4(src[ip..]);
        const ref = hash_table[h];
        hash_table[h] = @intCast(ip);

        if (ref == 0 or ip - ref > 0xFFFF or !mem.eql(u8, src[ref..][0..MIN_MATCH], src[ip..][0..MIN_MATCH])) {
            ip += 1;
            continue;
        }

        // ── encode literals before this match ──
        const lit_len = ip - anchor;
        const match_off = ip - ref;

        // extend match forward
        var match_len: usize = MIN_MATCH;
        while (ip + match_len < src.len and src[ref + match_len] == src[ip + match_len]) {
            match_len += 1;
        }

        // write token
        op = try writeToken(dst, op, lit_len, match_len - MIN_MATCH);

        // write literals
        @memcpy(dst[op..][0..lit_len], src[anchor..][0..lit_len]);
        op += lit_len;

        // write offset (little-endian u16)
        dst[op] = @intCast(match_off & 0xFF);
        dst[op + 1] = @intCast((match_off >> 8) & 0xFF);
        op += 2;

        // write extended match length
        if (match_len - MIN_MATCH >= ML_MASK) {
            op = writeLength(dst, op, match_len - MIN_MATCH - ML_MASK);
        }

        ip += match_len;
        anchor = ip;

        // insert hash for position right after match start (improves chain)
        if (ip < mf_limit) {
            hash_table[hash4(src[ip - 2 ..])] = @intCast(ip - 2);
        }
    }

    // ── last literals (everything from anchor to end) ──
    {
        const lit_len = src.len - anchor;
        // token with match_len = 0 → we write no offset
        const token_lit: u8 = if (lit_len >= RUN_MASK) RUN_MASK else @intCast(lit_len);
        dst[op] = token_lit << 4; // match part = 0 signals "last sequence"
        op += 1;
        if (lit_len >= RUN_MASK) {
            op = writeLength(dst, op, lit_len - RUN_MASK);
        }
        @memcpy(dst[op..][0..lit_len], src[anchor..][0..lit_len]);
        op += lit_len;
    }

    return op;
}

/// Upper bound on compressed size for a given input length.
pub fn compressBound(input_len: usize) usize {
    return input_len + (input_len / 255) + 16;
}

/// Decompress `src` (LZ4 block) into `dst` of exactly `original_len` bytes.
pub fn decompress(src: []const u8, dst: []u8, original_len: usize) !void {
    if (original_len == 0) return;

    var ip: usize = 0; // input cursor
    var op: usize = 0; // output cursor

    while (ip < src.len) {
        // ── read token ──
        const token = src[ip];
        ip += 1;

        // literal length
        var lit_len: usize = token >> 4;
        if (lit_len == RUN_MASK) {
            while (true) {
                if (ip >= src.len) return error.MalformedInput;
                const extra = src[ip];
                ip += 1;
                lit_len += extra;
                if (extra != 255) break;
            }
        }

        // copy literals
        if (ip + lit_len > src.len) return error.MalformedInput;
        if (op + lit_len > original_len) return error.OutputOverflow;
        @memcpy(dst[op..][0..lit_len], src[ip..][0..lit_len]);
        ip += lit_len;
        op += lit_len;

        if (op == original_len) return; // reached the end
        if (ip >= src.len) return error.MalformedInput;

        // ── match copy ──
        const offset: usize = @as(usize, src[ip]) | (@as(usize, src[ip + 1]) << 8);
        ip += 2;
        if (offset == 0) return error.MalformedInput;
        if (op < offset) return error.MalformedInput;

        var match_len: usize = (token & ML_MASK) + MIN_MATCH;
        if ((token & ML_MASK) == ML_MASK) {
            while (true) {
                if (ip >= src.len) return error.MalformedInput;
                const extra = src[ip];
                ip += 1;
                match_len += extra;
                if (extra != 255) break;
            }
        }

        if (op + match_len > original_len) return error.OutputOverflow;

        // byte-by-byte copy (handles overlapping matches)
        const match_start = op - offset;
        for (0..match_len) |i| {
            dst[op + i] = dst[match_start + i];
        }
        op += match_len;
    }

    if (op != original_len) return error.OutputMismatch;
}

// ── internal helpers ──

fn hash4(ptr: []const u8) usize {
    const v = mem.readInt(u32, ptr[0..4], .little);
    return @intCast((v *% 2654435761) >> (32 - HASH_LOG));
}

fn writeToken(dst: []u8, op: usize, lit_len: usize, ml: usize) !usize {
    const lit_part: u8 = if (lit_len >= RUN_MASK) RUN_MASK else @intCast(lit_len);
    const ml_part: u8 = if (ml >= ML_MASK) ML_MASK else @intCast(ml);
    dst[op] = (lit_part << 4) | ml_part;
    var pos = op + 1;
    if (lit_len >= RUN_MASK) {
        pos = writeLength(dst, pos, lit_len - RUN_MASK);
    }
    return pos;
}

fn writeLength(dst: []u8, start: usize, length: usize) usize {
    var remaining = length;
    var pos = start;
    while (remaining >= 255) {
        dst[pos] = 255;
        pos += 1;
        remaining -= 255;
    }
    dst[pos] = @intCast(remaining);
    return pos + 1;
}

// ============================================================================
// Tests
// ============================================================================

test "roundtrip empty" {
    var comp_buf: [64]u8 = undefined;
    const clen = try compress("", &comp_buf);
    try std.testing.expectEqual(@as(usize, 0), clen);
}

test "roundtrip small literal" {
    const input = "Hello!";
    var comp_buf: [128]u8 = undefined;
    const clen = try compress(input, &comp_buf);

    var decomp_buf: [input.len]u8 = undefined;
    try decompress(comp_buf[0..clen], &decomp_buf, input.len);
    try std.testing.expectEqualStrings(input, &decomp_buf);
}

test "roundtrip repeated data" {
    // repeated data should compress well
    const input = "ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD" ++
        "ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD" ++
        "ABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCDABCD";
    var comp_buf: [compressBound(input.len)]u8 = undefined;
    const clen = try compress(input, &comp_buf);

    // should actually compress
    try std.testing.expect(clen < input.len);

    var decomp_buf: [input.len]u8 = undefined;
    try decompress(comp_buf[0..clen], &decomp_buf, input.len);
    try std.testing.expectEqualStrings(input, &decomp_buf);
}

test "roundtrip incompressible" {
    // pseudo-random bytes — shouldn't crash, just not compress well
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast((i *% 137 + 43) & 0xFF);
    }
    var comp_buf: [compressBound(256)]u8 = undefined;
    const clen = try compress(&input, &comp_buf);

    var decomp_buf: [256]u8 = undefined;
    try decompress(comp_buf[0..clen], &decomp_buf, 256);
    try std.testing.expectEqualSlices(u8, &input, &decomp_buf);
}
