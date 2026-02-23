# Lethe

A minimal vi-like text editor written in [Zig](https://ziglang.org/) 0.15.

Lethe is a single-file terminal editor with a familiar modal interface. It was built from scratch with no dependencies beyond the Zig standard library — no curses, no terminfo, just raw ANSI escape sequences.

The name comes from the river of forgetfulness in Greek mythology. Your original file is never touched — Lethe always writes new versions alongside it.

## Features

- **Vi-style modal editing** — Normal and Insert modes with the keybindings you'd expect
- **Word-wrap display** — Long lines wrap at word boundaries (spaces, hyphens), not mid-word
- **Line numbers** — Dimmed gutter with right-aligned numbers; continuation lines show blank gutters so you always know what's a real line vs. a soft wrap
- **VMS-style file versioning** — Saves go to `file.txt.1`, `file.txt.2`, etc. The original is never overwritten. Highest number = newest version
- **Undo** — Snapshot-based with vi semantics: one undo per edit action, not per keystroke
- **Built-in help** — Press `?` to toggle a quick-reference overlay
- **I18n-ready** — All UI strings are constants at the top of the file

## Building

```
zig build-exe src/main.zig -o lethe
```

Or with a `build.zig`:

```
zig build
```

Requires **Zig 0.15.2** or compatible. Linux only (uses `ioctl` for terminal size and POSIX termios for raw mode).

To enable the `squash` command, create a symlink:

```bash
ln -s lethe squash
```

## Usage

```
./lethe myfile.txt
```

## Keybindings

### Normal Mode

| Key | Action |
|-----|--------|
| `i` | Insert before cursor |
| `a` | Insert after cursor |
| `A` | Insert at end of line |
| `o` | Open new line below |
| `O` | Open new line above |
| `dd` | Delete entire line |
| `d$` | Delete to end of line |
| `cw` | Change word (delete + insert) |
| `x` | Delete character under cursor |
| `u` | Undo last edit action |
| `h/j/k/l` | Move left/down/up/right |
| `←↑↓→` | Move (arrow keys also work) |
| `0` | Jump to start of line |
| `$` | Jump to end of line |
| `w` | Save (writes versioned file) |
| `q` | Quit (warns if unsaved) |
| `?` | Toggle help overlay |

### Insert Mode

| Key | Action |
|-----|--------|
| Any printable | Insert character |
| `Enter` | Split line |
| `Backspace` | Delete backward / join lines |
| `Delete` | Delete forward / join lines |
| `←↑↓→` | Move cursor |
| `Esc` | Return to Normal mode |

## File Versioning

Lethe never modifies your original file. When you press `w`:

```
myfile.txt      ← original, untouched
myfile.txt.1    ← first save
myfile.txt.2    ← second save
myfile.txt.3    ← third save (newest)
```

The status bar confirms which version was written.

### Squash

Over time, versions accumulate. To consolidate, use the `squash` command — the same binary, invoked via symlink:

```bash
ln -s lethe squash
```

```bash
./squash myfile.txt
# myfile.txt.3 -> myfile.txt (2 version(s) removed)
```

This finds the highest-numbered version, deletes everything else (including the original), and renames the newest version to the original filename. One command, clean slate.

## Architecture

The entire editor is a single Zig source file (~820 lines). Key design decisions:

- **ArenaAllocator** — All memory is arena-allocated. Nothing is individually freed until the editor exits. This keeps the code simple and makes undo snapshots essentially free.
- **Raw terminal mode** — POSIX termios with `ICANON`, `ECHO`, `ISIG` disabled. Alternate screen buffer so your terminal is restored on exit.
- **Buffered I/O** — Uses Zig 0.15's new `std.Io.Writer` interface with a 4K buffer. One flush per render cycle.
- **Word-wrap** — `wrapPositions()` scans for spaces and hyphens to find natural break points. Falls back to hard wrap for long unbroken strings (URLs, etc.).
- **Operator-pending state** — For compound commands like `dd`, `d$`, `cw`. A single `pending_op` byte remembers the first keystroke.
- **Multi-personality binary** — The same binary acts as editor or version squasher depending on `argv[0]`. A symlink is all it takes.

## Limitations

- No syntax highlighting
- No search (`/`)
- No yank/paste (`y`/`p`)
- No multi-file editing
- No redo (only undo)
- Linux only (POSIX termios + Linux ioctl)
- Maximum ~256 visual wrap lines per source line

## Localization

All user-facing strings live in the `strings` struct at the top of the file. To translate the UI, just change those constants:

```zig
const strings = struct {
    const mode_normal = "NORMAL";
    const mode_insert = "INSERT";
    const label_line = "Line";
    const label_col = "Col";
    // ...
};
```

## License

MIT
