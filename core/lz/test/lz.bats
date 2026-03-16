#!/usr/bin/env bats

# Integration tests for lzpack (lz) CLI
# Requires: bats-core, zig-out/bin/lz in PATH or via LZ variable

setup() {
    LZ="${LZ:-./zig-out/bin/lz}"
    TEST_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ── roundtrip tests ──

@test "roundtrip: repeated text compresses and decompresses correctly" {
    yes "The quick brown fox jumps over the lazy dog" | head -c 10240 > "$TEST_DIR/input.txt"

    run "$LZ" pack "$TEST_DIR/input.txt" "$TEST_DIR/input.txt.lz"
    [ "$status" -eq 0 ]

    run "$LZ" unpack "$TEST_DIR/input.txt.lz" "$TEST_DIR/output.txt"
    [ "$status" -eq 0 ]

    diff "$TEST_DIR/input.txt" "$TEST_DIR/output.txt"
}

@test "roundtrip: random data survives pack/unpack" {
    dd if=/dev/urandom of="$TEST_DIR/random.bin" bs=1024 count=10 2>/dev/null

    run "$LZ" pack "$TEST_DIR/random.bin" "$TEST_DIR/random.bin.lz"
    [ "$status" -eq 0 ]

    run "$LZ" unpack "$TEST_DIR/random.bin.lz" "$TEST_DIR/random_out.bin"
    [ "$status" -eq 0 ]

    diff "$TEST_DIR/random.bin" "$TEST_DIR/random_out.bin"
}

@test "roundtrip: single byte file" {
    printf 'X' > "$TEST_DIR/one.txt"

    run "$LZ" pack "$TEST_DIR/one.txt" "$TEST_DIR/one.txt.lz"
    [ "$status" -eq 0 ]

    run "$LZ" unpack "$TEST_DIR/one.txt.lz" "$TEST_DIR/one_out.txt"
    [ "$status" -eq 0 ]

    diff "$TEST_DIR/one.txt" "$TEST_DIR/one_out.txt"
}

@test "roundtrip: empty file" {
    touch "$TEST_DIR/empty.txt"

    run "$LZ" pack "$TEST_DIR/empty.txt" "$TEST_DIR/empty.txt.lz"
    [ "$status" -eq 0 ]

    run "$LZ" unpack "$TEST_DIR/empty.txt.lz" "$TEST_DIR/empty_out.txt"
    [ "$status" -eq 0 ]

    diff "$TEST_DIR/empty.txt" "$TEST_DIR/empty_out.txt"
}

@test "roundtrip: larger file (1 MiB repeated pattern)" {
    yes "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" | head -c 1048576 > "$TEST_DIR/big.txt"

    run "$LZ" pack "$TEST_DIR/big.txt" "$TEST_DIR/big.txt.lz"
    [ "$status" -eq 0 ]

    run "$LZ" unpack "$TEST_DIR/big.txt.lz" "$TEST_DIR/big_out.txt"
    [ "$status" -eq 0 ]

    diff "$TEST_DIR/big.txt" "$TEST_DIR/big_out.txt"
}

# ── compression ratio ──

@test "repeated text actually compresses (ratio < 100%)" {
    yes "The quick brown fox jumps over the lazy dog" | head -c 10240 > "$TEST_DIR/input.txt"

    "$LZ" pack "$TEST_DIR/input.txt" "$TEST_DIR/input.txt.lz"

    input_size=$(stat -c%s "$TEST_DIR/input.txt")
    archive_size=$(stat -c%s "$TEST_DIR/input.txt.lz")
    [ "$archive_size" -lt "$input_size" ]
}

# ── default naming ──

@test "pack uses .lz extension by default" {
    printf 'hello world\n' > "$TEST_DIR/hello.txt"

    cd "$TEST_DIR"
    run "$OLDPWD/$LZ" pack hello.txt
    [ "$status" -eq 0 ]
    [ -f "hello.txt.lz" ]
}

@test "unpack strips .lz extension by default" {
    printf 'hello world\n' > "$TEST_DIR/hello.txt"

    "$LZ" pack "$TEST_DIR/hello.txt" "$TEST_DIR/hello.txt.lz"
    rm "$TEST_DIR/hello.txt"

    cd "$TEST_DIR"
    run "$OLDPWD/$LZ" unpack hello.txt.lz
    [ "$status" -eq 0 ]
    [ -f "hello.txt" ]
}

# ── error handling ──

@test "pack: missing input file exits non-zero" {
    run "$LZ" pack "$TEST_DIR/nonexistent.txt"
    [ "$status" -ne 0 ]
}

@test "unpack: truncated archive exits non-zero" {
    printf 'LZ4!' > "$TEST_DIR/broken.lz"

    run "$LZ" unpack "$TEST_DIR/broken.lz" "$TEST_DIR/out.txt"
    [ "$status" -ne 0 ]
}

@test "unpack: wrong magic exits non-zero" {
    printf 'NOPE' > "$TEST_DIR/fake.lz"
    # pad to at least 20 bytes
    dd if=/dev/zero bs=1 count=16 >> "$TEST_DIR/fake.lz" 2>/dev/null

    run "$LZ" unpack "$TEST_DIR/fake.lz" "$TEST_DIR/out.txt"
    [ "$status" -ne 0 ]
}

@test "no arguments prints usage and exits non-zero" {
    run "$LZ"
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage"* ]]
}

@test "unknown command exits non-zero" {
    run "$LZ" compress "$TEST_DIR/whatever"
    [ "$status" -ne 0 ]
}

# ── original file preservation ──

@test "pack does not delete original file" {
    printf 'keep me\n' > "$TEST_DIR/keep.txt"

    "$LZ" pack "$TEST_DIR/keep.txt" "$TEST_DIR/keep.txt.lz"

    [ -f "$TEST_DIR/keep.txt" ]
    [ -f "$TEST_DIR/keep.txt.lz" ]
}

@test "unpack does not delete archive" {
    printf 'keep me\n' > "$TEST_DIR/keep.txt"
    "$LZ" pack "$TEST_DIR/keep.txt" "$TEST_DIR/keep.txt.lz"

    "$LZ" unpack "$TEST_DIR/keep.txt.lz" "$TEST_DIR/keep_out.txt"

    [ -f "$TEST_DIR/keep.txt.lz" ]
    [ -f "$TEST_DIR/keep_out.txt" ]
}
