[![Release](https://github.com/kkroesch/zish/actions/workflows/release.yml/badge.svg)](https://github.com/kkroesch/zish/actions/workflows/release.yml)

<center>
  <img src="logo.png" width="250px">
</center>

# zish - A Minimal Shell in Zig

A POSIX-ish shell written in Zig with GNU Readline and SQLite-backed persistent state.

## The Idea

Your shell environment lives in a single SQLite file (`~/.zish.db`). History,
environment variables, aliases — everything is portable. Copy the file to
another machine and pick up right where you left off.

```bash
# On machine A
scp ~/.zish.db user@machine-b:~/.zish.db

# On machine B
zish  # all your history, aliases, and env vars are there
```

Or use a custom database:

```bash
zish --db ~/projects/myproject/.zish.db
```

## Features

- **SQLite-backed persistence**: History, environment, aliases, settings
- **Prefix-based history search**: Type `git ` then press ↑ to find only git commands
- **Rich history**: Every command stored with timestamp, working directory, and exit code
- **Portable environment**: `export` persists to DB, loads on startup
- **Persistent aliases**: `alias` writes to DB, available across sessions
- **Command lists**: `&&` and `||` for conditional execution
- **Command substitution**: `$(command)` captured and expanded inline
- **Glob expansion**: `*`, `?`, `[...]` patterns via POSIX `glob(3)`
- **Pipes & redirects**: `|`, `>`, `>>`, `<`
- **Variable expansion**: `$HOME`, `$USER`, `$?` (last exit code)
- **Exit code indicator**: Red ✘ in prompt when last command failed
- **Alias expansion**: First word is checked against alias DB
- **SIGINT handling**: Ctrl-C won't kill the shell

## Builtins

| Command                  | Description                              |
|--------------------------|------------------------------------------|
| `cd [dir]`               | Change directory (~ supported)           |
| `pwd`                    | Print working directory                  |
| `exit`                   | Exit the shell                           |
| `export KEY=VAL`         | Set & persist environment variable       |
| `export`                 | List persisted environment variables     |
| `unset KEY`              | Remove environment variable              |
| `alias name=command`     | Set & persist alias                      |
| `alias`                  | List all aliases                         |
| `unalias name`           | Remove alias                             |
| `history`                | Show readline history                    |
| `history search PREFIX`  | Search DB history by prefix              |
| `history stats`          | Show history statistics                  |
| `query SQL`              | Execute SQL, output as table (default)   |
| `query --json SQL`       | Execute SQL, output as JSON              |
| `query --csv SQL`        | Execute SQL, output as CSV               |
| `dbinfo`                 | Show database information                |
| `help`                   | Show help                                |

## Database Schema

```sql
history     (id, command, cwd, timestamp, exit_code)
environment (key, value)
aliases     (name, command)
settings    (key, value)
```

The database uses WAL mode for performance and safe concurrent access.

## Build

### Prerequisites

- Zig >= 0.15.0
- GNU Readline development headers
- SQLite3 development headers

```bash
# Fedora
sudo dnf install readline-devel sqlite-devel

# Debian/Ubuntu
sudo apt install libreadline-dev libsqlite3-dev

# For static linking (Fedora)
sudo dnf install readline-static sqlite-static
```

### Compile & Run

```bash
zig build
./zig-out/bin/zish
```

### Static Linking

For a fully portable binary, change `build.zig`:

```zig
exe.linkSystemLibrary2("readline", .{ .preferred_link_mode = .static });
exe.linkSystemLibrary2("sqlite3", .{ .preferred_link_mode = .static });
```

## Query Builtin

Direct SQL access to your shell database with multiple output formats:

```bash
# Table format (default)
query SELECT command, exit_code FROM history WHERE cwd LIKE '%/myproject%' LIMIT 5

# JSON output - pipe to jq, store, or send to an API
query --json SELECT key, value FROM environment

# CSV output - import into spreadsheets or other tools
query --csv SELECT command, count(*) as n FROM history GROUP BY command ORDER BY n DESC LIMIT 20
```

## History Search

Prefix-based search is built in — no `~/.inputrc` needed:

| Key       | Action                          |
|-----------|---------------------------------|
| `↑`       | Search backward (prefix match)  |
| `↓`       | Search forward (prefix match)   |
| `Ctrl-P`  | Search backward (prefix match)  |
| `Ctrl-N`  | Search forward (prefix match)   |

Additionally, `history search git` searches the SQLite database directly,
showing timestamp, exit status, and working directory for each match.

## License

GPL-3.0-or-later
