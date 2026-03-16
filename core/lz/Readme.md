# lz

A minimal single-file compressor/decompressor using LZ4 block compression, written in Zig with zero dependencies. Statically linked against musl — no runtime dependencies, single binary, runs anywhere.

## Build

Requires Zig 0.15+.

```
zig build -Doptimize=ReleaseSafe
```

For smallest binary size:

```
zig build -Doptimize=ReleaseSmall
```

The binary lands in `zig-out/bin/lz`. It is fully static (`ldd` will report "not a dynamic executable").

## Usage

```
lz pack <file> [output.lz]
lz unpack <file.lz> [output]
```

Original files are never modified or deleted.

```
$ lz pack kernel.img
kernel.img → kernel.img.lz  (4194304 → 1287651 bytes, 30.7%)

$ lz unpack kernel.img.lz
kernel.img.lz → kernel.img  (4194304 bytes)
```

If no output path is given, `pack` appends `.lz` and `unpack` strips it.

## File Format

The `.lz` container is intentionally trivial — a 20-byte header followed by the compressed LZ4 block:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | Magic: `LZ4!` (0x4C 0x5A 0x34 0x21) |
| 4 | 8 | Original size (little-endian u64) |
| 12 | 8 | Compressed size (little-endian u64) |
| 20 | N | LZ4 block data |

No checksums, no framing, no multi-file support. This is a single-file compressor.

## Testing

Unit tests (LZ4 codec roundtrips):

```
zig build test
```

Integration tests (requires [bats-core](https://github.com/bats-core/bats-core)):

```
bats test/lz.bats
```

## Project Structure

```
├── build.zig          # Build config (musl, static, x86_64)
├── src/
│   ├── main.zig       # CLI, .lz container format, file I/O
│   └── lz4.zig        # LZ4 block codec (compress + decompress)
└── test/
    └── lz.bats        # BATS integration tests
```

`lz4.zig` is a self-contained module with no I/O and no allocator usage in the hot path. It can be embedded in other Zig projects via `@import("lz4.zig")`.

## Why

Built as a utility for [StyxOS](https://github.com/styxos-org/styxos) — a minimal immutable Linux distribution with a Zig-based userland. The LZ4 codec is intended for internal use (provisioning bundles, metric buffers) rather than as an archive format.

## License

GPL v3
