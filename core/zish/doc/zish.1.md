% zish(1) Version 0.1.0 | Zish User Manual

# NAME

zish - A minimal shell in Zig with SQLite-backed persistence

# SYNOPSIS

**zish** [*options*] [*script_file*]

# DESCRIPTION

**zish** is a POSIX-ish shell written in Zig. Unlike traditional shells that use plain text files for history and configuration, **zish** stores its entire state—history, environment variables, aliases, and settings—in a single SQLite database.

This design allows for robust persistence and portability. By copying the database file, you can transfer your entire shell environment to another machine.

# OPTIONS

**-c** *command*
:   Execute the specified command string and exit.

**--db** *path*
:   Use a custom database file instead of the default `~/.zish.db`.

**--help**
:   Display help information.

**--version**
:   Display version information.

# KEY BINDINGS

**zish** provides line editing capabilities with persistent history search.

**Up / Ctrl-P**
:   Search history backward. If you have typed a prefix, it searches for commands starting with that prefix.

**Down / Ctrl-N**
:   Search history forward (prefix match).

**Ctrl-A**
:   Move cursor to the beginning of the line.

**Ctrl-E**
:   Move cursor to the end of the line.

# BUILTINS

**zish** includes several builtin commands.

**cd** [*dir*]
:   Change the current directory. Supports `~` expansion.

**pwd**
:   Print the current working directory.

**export** *KEY=VAL*
:   Set an environment variable and persist it to the database.

**export**
:   List all persisted environment variables.

**unset** *KEY*
:   Remove an environment variable from the session and database.

**alias** *name=command*
:   Create an alias and persist it to the database.

**alias**
:   List all defined aliases.

**unalias** *name*
:   Remove an alias.

**history**
:   Show the recent command history.

**history search** *PREFIX*
:   Search the SQLite history database for commands starting with *PREFIX*.

**history stats**
:   Show statistics about command usage.

**query** [*options*] *SQL*
:   Execute a raw SQL query against the shell database.
    
    **--json** Output result as JSON.
    **--csv** Output result as CSV.

**dbinfo**
:   Show information about the connected database file.

**exit** [*code*]
:   Exit the shell with an optional status code.

# DATABASE SCHEMA

The internal SQLite database uses the following schema:

* **history** (id, command, cwd, timestamp, exit_code)
* **environment** (key, value)
* **aliases** (name, command)
* **settings** (key, value)

# FILES

**~/.zish.db**
:   The default location for the persistent state database.

# EXIT STATUS

**zish** returns the exit status of the last command executed. If the last command failed, the prompt may indicate this (e.g., with a red cross).

# EXAMPLES

**Export and persist a variable:**
.RS
$ export EDITOR=nvim
.RE

**Query your command history:**
.RS
$ query "SELECT command, count(*) as n FROM history GROUP BY command ORDER BY n DESC LIMIT 5"
.RE

**Run with a project-specific database:**
.RS
$ zish --db ./project.db
.RE

# AUTHORS

Written by Karsten Kroesch.

# COPYRIGHT

License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.