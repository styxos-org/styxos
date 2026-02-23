#!/usr/bin/env bats

# zish test suite
# Requires: bats-core (https://github.com/bats-core/bats-core)
# Run: bats test/zish.bats

bats_require_minimum_version 1.5.0

setup() {
  ZISH="${ZISH:-./zig-out/bin/zish}"
  TEST_DB=$(mktemp /tmp/zish-test-XXXXXX.db)
  ZISH_CMD="$ZISH --db $TEST_DB"

  # Seed test data (suppress output)
  $ZISH_CMD -c 'export TESTKEY=testval' 2>/dev/null
  $ZISH_CMD -c 'export JSONTEST=42' 2>/dev/null
  $ZISH_CMD -c 'alias greet=echo' 2>/dev/null
  $ZISH_CMD -c 'config mykey myvalue' 2>/dev/null
  $ZISH_CMD -c 'config delkey temporary' 2>/dev/null
}

teardown() {
  rm -f "$TEST_DB"
}

# ── Basic Command Execution ──────────────────────────────────────────

@test "should execute a simple echo command" {
  run $ZISH_CMD -c 'echo hello'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "should pass arguments to external commands" {
  run $ZISH_CMD -c 'echo one two three'
  [ "$status" -eq 0 ]
  [ "$output" = "one two three" ]
}

@test "should propagate exit code from failed commands" {
  run $ZISH_CMD -c 'false'
  [ "$status" -eq 1 ]
}

@test "should propagate exit code 0 from successful commands" {
  run $ZISH_CMD -c 'true'
  [ "$status" -eq 0 ]
}

@test "should report command not found with exit code 127" {
  run -127 $ZISH_CMD -c 'nonexistent_command_xyz'
  [ "$status" -eq 127 ]
}

# ── Pipe Operator ────────────────────────────────────────────────────

@test "should pipe stdout of one command into stdin of another" {
  run $ZISH_CMD -c 'echo hello | tr h H'
  [ "$status" -eq 0 ]
  [ "$output" = "Hello" ]
}

@test "should support chaining multiple pipes" {
  run $ZISH_CMD -c 'echo hello world | tr h H | tr w W'
  [ "$status" -eq 0 ]
  [ "$output" = "Hello World" ]
}

@test "should handle pipe without spaces around operator" {
  run $ZISH_CMD -c 'echo hello|cat'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "should return exit code of last command in pipeline" {
  run $ZISH_CMD -c 'echo hello | false'
  [ "$status" -eq 1 ]
}

# ── Conditional Operators (&&, ||) ───────────────────────────────────

@test "should execute second command when first succeeds (&&)" {
  run $ZISH_CMD -c 'true && echo yes'
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

@test "should skip second command when first fails (&&)" {
  run $ZISH_CMD -c 'false && echo should_not_appear'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "should execute second command when first fails (||)" {
  run $ZISH_CMD -c 'false || echo fallback'
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "should skip second command when first succeeds (||)" {
  run $ZISH_CMD -c 'true || echo should_not_appear'
  [ "$status" -eq 0 ]
  [ "$output" != "should_not_appear" ]
}

@test "should chain && and || operators" {
  run $ZISH_CMD -c 'true && echo ok || echo fail'
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "should handle && without spaces" {
  run $ZISH_CMD -c 'true&&echo yes'
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

# ── Command Substitution $() ─────────────────────────────────────────

@test "should substitute command output inline" {
  run $ZISH_CMD -c 'echo $(echo inner)'
  [ "$status" -eq 0 ]
  [ "$output" = "inner" ]
}

@test "should strip trailing newlines from command substitution" {
  run $ZISH_CMD -c 'echo hello_$(echo world)'
  [ "$status" -eq 0 ]
  [ "$output" = "hello_world" ]
}

@test "should handle command substitution with pipes" {
  run $ZISH_CMD -c 'echo $(echo hello | tr h H)'
  [ "$status" -eq 0 ]
  [ "$output" = "Hello" ]
}

@test "should execute builtins inside command substitution" {
  run $ZISH_CMD -c 'echo $(dbinfo | head -1)'
  [ "$status" -eq 0 ]
  [[ "$output" == *"zish"* ]]
}

# ── Variable Expansion ───────────────────────────────────────────────

@test "should expand HOME variable" {
  run $ZISH_CMD -c 'echo $HOME'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME" ]
}

@test "should expand exit code variable \$?" {
  run $ZISH_CMD -c 'true && echo $?'
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "should leave undefined variables as empty string" {
  run $ZISH_CMD -c 'echo x$UNDEFINED_ZISH_VAR_XYZ'
  [ "$status" -eq 0 ]
  [ "$output" = "x" ]
}

# ── Globbing ─────────────────────────────────────────────────────────

@test "should expand glob patterns to matching files" {
  local tmpdir=$(mktemp -d /tmp/zish-glob-XXXXXX)
  touch "$tmpdir/a.txt" "$tmpdir/b.txt" "$tmpdir/c.log"
  run $ZISH_CMD -c "ls $tmpdir/*.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.txt"* ]]
  [[ "$output" == *"b.txt"* ]]
  [[ "$output" != *"c.log"* ]]
  rm -rf "$tmpdir"
}

@test "should keep unmatched glob pattern as literal" {
  run $ZISH_CMD -c 'echo /nonexistent_path_xyz/*.nothing'
  [ "$status" -eq 0 ]
  [ "$output" = "/nonexistent_path_xyz/*.nothing" ]
}

# ── Redirects ────────────────────────────────────────────────────────

@test "should redirect stdout to a file" {
  local tmpfile=$(mktemp /tmp/zish-redir-XXXXXX)
  run $ZISH_CMD -c "echo hello > $tmpfile"
  [ "$status" -eq 0 ]
  [ "$(cat $tmpfile)" = "hello" ]
  rm -f "$tmpfile"
}

@test "should append stdout to a file" {
  local tmpfile=$(mktemp /tmp/zish-redir-XXXXXX)
  echo "first" > "$tmpfile"
  run $ZISH_CMD -c "echo second >> $tmpfile"
  [ "$status" -eq 0 ]
  [ "$(cat $tmpfile)" = "first
second" ]
  rm -f "$tmpfile"
}

@test "should redirect stdin from a file" {
  local tmpfile=$(mktemp /tmp/zish-redir-XXXXXX)
  echo "from file" > "$tmpfile"
  run $ZISH_CMD -c "cat < $tmpfile"
  [ "$status" -eq 0 ]
  [ "$output" = "from file" ]
  rm -f "$tmpfile"
}

# ── Quoting ──────────────────────────────────────────────────────────

@test "should handle double-quoted strings with spaces" {
  run $ZISH_CMD -c 'echo "hello world"'
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "should handle single-quoted strings with spaces" {
  run $ZISH_CMD -c "echo 'hello world'"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

# ── Builtins ─────────────────────────────────────────────────────────

@test "should change directory with cd" {
  run $ZISH_CMD -c 'cd /tmp && pwd'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp" ]
}

@test "should print working directory with pwd" {
  run $ZISH_CMD -c 'pwd'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "should export and read environment variables" {
  $ZISH_CMD -c 'export ZISH_TEST_VAR=hello' 2>/dev/null
  run $ZISH_CMD -c 'echo $ZISH_TEST_VAR'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "should persist aliases across -c invocations" {
  run $ZISH_CMD -c 'greet hello'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "should show help without errors" {
  run $ZISH_CMD -c 'help'
  [ "$status" -eq 0 ]
  [[ "$output" == *"zish"* ]]
}

@test "should show database info" {
  run $ZISH_CMD -c 'dbinfo'
  [ "$status" -eq 0 ]
  [[ "$output" == *"History"* ]]
}

# ── Query Builtin ────────────────────────────────────────────────────

@test "should execute SQL query with table output" {
  run $ZISH_CMD -c 'query SELECT key, value FROM environment'
  [ "$status" -eq 0 ]
  [[ "$output" == *"TESTKEY"* ]]
  [[ "$output" == *"testval"* ]]
}

@test "should output query results as JSON" {
  # run $ZISH_CMD -c "query --json SELECT key, value FROM environment WHERE key = 'JSONTEST'"
  run $ZISH_CMD -c "query --json SELECT key, value FROM environment"
  [ "$status" -eq 0 ]
  [[ "$output" == *'JSONTEST'* ]]
  [[ "$output" == *'42'* ]]
}

@test "should output query results as CSV" {
  $ZISH_CMD -c 'export CSVTEST=hello' 2>/dev/null
  #run $ZISH_CMD -c "query --csv SELECT key, value FROM environment WHERE key = 'CSVTEST'"
  run $ZISH_CMD -c "query --csv SELECT key, value FROM environment"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CSVTEST"* ]]
  [[ "$output" == *"hello"* ]]
}

# ── Config Builtin ───────────────────────────────────────────────────

@test "should set and retrieve config values" {
  run $ZISH_CMD -c 'config mykey'
  [ "$status" -eq 0 ]
  [[ "$output" == *"myvalue"* ]]
}

@test "should unset config values" {
  $ZISH_CMD -c 'config delkey --unset'
  run $ZISH_CMD -c 'config delkey'
  [ "$status" -eq 0 ]
  [[ "$output" == *"not set"* ]]
}

# ── Database Isolation ───────────────────────────────────────────────

@test "should use separate database with --db flag" {
  local db1=$(mktemp /tmp/zish-db1-XXXXXX.db)
  local db2=$(mktemp /tmp/zish-db2-XXXXXX.db)
  $ZISH --db "$db1" -c 'export SCOPE=db1'
  $ZISH --db "$db2" -c 'export SCOPE=db2'
  run $ZISH --db "$db1" -c 'echo $SCOPE'
  [ "$output" = "db1" ]
  run $ZISH --db "$db2" -c 'echo $SCOPE'
  [ "$output" = "db2" ]
  rm -f "$db1" "$db2"
}

# ── Builtin in Pipeline ─────────────────────────────────────────────

@test "should pipe builtin output to external command" {
  run $ZISH_CMD -c 'help | head -1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"zish"* ]]
}

