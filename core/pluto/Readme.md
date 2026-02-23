# sysmon

Lightweight system metrics collector written in Zig 0.15.2. Reads kernel
metrics from `/proc` and `/sys`, stores them in SQLite with JSON payloads.

## Collected Metrics

| Kind        | Source               | Fields                                              |
|-------------|----------------------|-----------------------------------------------------|
| `cpu`       | `/proc/stat`         | user%, system%, iowait%, idle%                      |
| `load`      | `/proc/loadavg`      | avg1, avg5, avg15, running, total                   |
| `mem`       | `/proc/meminfo`      | total, available, used, buffers, cached, swap        |
| `net`       | `/proc/net/dev`      | rx/tx bytes, packets, errors, byte rate             |
| `diskio`    | `/proc/diskstats`    | reads, writes, read/write byte rate, io time        |
| `diskspace` | `statvfs()`          | total, free, avail, used%                           |

## Build

```sh
# Requires Zig 0.15.2 and libsqlite3-dev
zig build

# Release build (static, musl)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
```

## Usage

```sh
# Default: writes to /var/lib/sysmon/metrics.db every 5 seconds
sudo mkdir -p /var/lib/sysmon
sudo sysmon

# Custom path and interval
sysmon --db ./metrics.db --interval 10
```

## Query

```sh
# Use the included helper
chmod +x sysmon-query.sh
SYSMON_DB=./metrics.db ./sysmon-query.sh --summary

# Or query directly
sqlite3 metrics.db "SELECT datetime(ts,'unixepoch','localtime'), json
                     FROM metrics WHERE kind='cpu'
                     ORDER BY ts DESC LIMIT 5;"
```

## Schema

```sql
CREATE TABLE metrics (
    ts      INTEGER NOT NULL,   -- unix epoch
    kind    TEXT NOT NULL,       -- cpu, load, mem, net, diskio, diskspace
    device  TEXT NOT NULL DEFAULT '',  -- eth0, sda, /, ...
    json    TEXT NOT NULL        -- metric payload
);
```

JSON payloads keep the schema extensible – no migrations needed when
adding container metrics later.

## Architecture Notes

- **Delta-based metrics** (CPU, net, disk I/O): First sample establishes
  baseline, rates appear from the second tick onward.
- **SQLite WAL mode**: Allows concurrent reads while the collector writes.
- **Batch inserts**: All metrics per tick wrapped in a single transaction.
- **Writergate** (Zig 0.15): All I/O uses explicit buffers + flush.
- **Zero allocations** in the hot path: Stack buffers throughout.

## Future: Container Metrics

Container CPU/memory/IO from cgroups v2:

```
/sys/fs/cgroup/<container>/cpu.stat
/sys/fs/cgroup/<container>/memory.current
/sys/fs/cgroup/<container>/io.stat
```

The JSON payload approach makes adding these trivial – just add a new
`kind` value (e.g. `container_cpu`) with the container name as `device`.

