# Init

Init is the first application to run on a StyxOS system (PID 1). It mounts
the base filesystems, runs a one-shot setup script, supervises a console
shell, reaps orphaned processes, and performs an orderly shutdown.

## Responsibilities

1. Mount `/proc`, `/sys`, `/dev` (devtmpfs), `/sys/fs/cgroup` (cgroup2), and
   the `/var` data partition (`/dev/vda`, ext4).
2. Bind stdin/stdout/stderr to `/dev/console`.
3. Run `/sbin/setup.sh` (network, time, ...) and wait for it to finish.
   Failures are logged but non-fatal.
4. Fork and supervise `/bin/sh` on the console, respawning it if it exits.
   Since PID 1 inherits every orphaned process, the same wait loop also
   reaps zombies system-wide.
5. On SIGTERM/SIGINT: signal every process (SIGTERM, then SIGKILL after a
   grace period), reap them, sync disks, and power off.

`main()` returns `void`, not `!void` — PID 1 must never exit, and the kernel
panics if it does, so no error is allowed to propagate out of `main`.

## Build modes

The `-Dinteractive` build option controls how the console shell is set up:

- **interactive** (default for `-Doptimize=Debug`): the shell gets its own
  session and controlling TTY, so job control (Ctrl+C, Ctrl+Z) works —
  useful for development in QEMU.
- **non-interactive** (default otherwise): the shell gets its own process
  group instead, so init can signal the whole service tree via `kill(-pid)`.

```
zig build                                   # dev build
zig build -Doptimize=ReleaseSmall -Dinteractive=false   # production build
```

See the [Justfile](Justfile) for the corresponding `just build` / `just release` targets.

## Known risks / limitations

- **No fsck before mounting `/var`.** `/dev/vda` is mounted as ext4 directly;
  after an unclean shutdown the kernel replays the journal but does not
  detect deeper corruption. The shutdown path mitigates this by giving
  processes a chance to exit cleanly before power-off, but there is no
  explicit remount-ro or fsck step.
- **SIGTERM and SIGINT both trigger power-off.** Convention on most systems
  is SIGINT (Ctrl-Alt-Del) → reboot, SIGTERM → power-off. Currently both
  signals do the same thing.
- **`setup.sh` runs with no timeout.** If the script hangs (e.g. waiting on
  a network device that never appears), boot hangs with it.
- **Small signal race remains in the reap loop.** If a shutdown signal
  arrives in the narrow window between checking the shutdown flag and
  entering `wait4`, the loop can block for up to one more child exit before
  noticing. A fully race-free implementation would need `signalfd`/`pselect`;
  given the target use case (short-lived container-style workloads) this
  was judged not worth the added complexity, but is worth revisiting if
  shutdown latency ever becomes an issue.
- **No privilege dropping.** Everything, including `setup.sh` and the
  console shell, runs as root. Acceptable for a minimal init on a
  single-purpose system, but worth keeping in mind if StyxOS ever hosts
  less-trusted workloads.
