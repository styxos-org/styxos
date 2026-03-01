# Charon

Minimal DNS resolver for the StyxOS ecosystem. Written in Zig.

## Features

- **Local zones** — A, AAAA, CNAME, TXT records in SQLite (in-memory), no cache TTLs
- **Forwarding** — Recursive resolution via Quad9 (9.9.9.9) or Cloudflare (1.1.1.1), configurable
- **Cache** — Separate SQLite table for previously resolved upstream records with TTL-based eviction
- **Control socket** — Unix socket (`/run/charon.sock`) for live management via `charonctl`

## Architecture

```
                    ┌─────────────────────────────────┐
   UDP :53          │           Charon                │
  ─────────────────>│                                 │
                    │  1. Lookup local_zones (SQLite) │
                    │     ↓ miss                      │
                    │  2. Lookup cache (SQLite)       │
                    │     ↓ miss                      │
                    │  3. Forward → upstream          │──> 9.9.9.9 / 1.1.1.1
                    │     cache response              │
                    └─────────────────────────────────┘
                              ↑
    Unix Socket               │
   ───────────────────────────┘
   charonctl flush/add/del
```

## Build

```sh
zig build
# Binaries: zig-out/bin/charon, zig-out/bin/charonctl
```

Requires `libsqlite3` (statically linked via musl on StyxOS).

For static linking (typical StyxOS build):

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall
```

## Configuration

```sh
cp charon.conf.example /etc/charon/charon.conf
cp zones.example /etc/charon/zones
```

Pass the config file as the first argument. Default: `/etc/charon/charon.conf`

```sh
charon /etc/charon/charon.conf
```

### Zone file format

Simple text format, one record per line:

```
name  TYPE  value  [ttl]
```

## Usage

### Flush cache

```sh
charonctl flush
```

### Add records at runtime

```sh
charonctl add myhost.local A 192.168.1.50
charonctl add myhost.local AAAA fd00::50
charonctl add alias.local CNAME target.local
charonctl add myhost.local TXT "key=value"
```

### Delete records

```sh
charonctl del myhost.local A
```

### Evict expired cache entries

```sh
charonctl evict
```

## Design decisions

- **SQLite in-memory** — No disk I/O, fast lookups, simple schema
- **Local zones without TTL** — Records from local zones are always served immediately, no caching needed
- **Separate cache table** — Clear separation between authoritative local data and cached upstream responses
- **Unix control socket** — `charonctl flush` is all it takes, no HTTP/REST overhead
- **Single-threaded** — Single-threaded event loop, appropriate for StyxOS use cases

## StyxOS integration

In your StyxOS `init` configuration:

```
service charon {
    exec = /usr/bin/charon /etc/charon/charon.conf
    depends = network
}
```

`/etc/resolv.conf`:

```
nameserver 127.0.0.1
```

## License

GPL v3.0 -- Part of the StyxOS project.
