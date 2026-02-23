#!/usr/bin/env bats

setup() {
    # Use local files for testing
    export STYLO_DB="test_log.db"
    export STYLO_SOCK="test_log.sock"
    rm -f "$STYLO_DB" "$STYLO_DB-wal" "$STYLO_DB-shm" "$STYLO_SOCK"
}

teardown() {
    # Optional: cleanup after tests
    # rm -f "$STYLO_DB" "$STYLO_DB-wal" "$STYLO_DB-shm" "$STYLO_SOCK"
    echo "Cleanup complete"
}

@test "oneshot: writing and reading a log entry" {
    # Run oneshot command (compiled binary)
    run ./target/debug/stylo test_src INFO "Hello StyxOS"
    [ "$status" -eq 0 ]

    # Verify database entry using sqlite3 CLI
    result=$(sqlite3 "$STYLO_DB" "SELECT message FROM logs WHERE source='test_src';")
    [ "$result" == "Hello StyxOS" ]
}

@test "daemon: receiving logs via unix socket" {
    # Start daemon in background
    ./target/debug/stylo -d &
    DAEMON_PID=$!

    # Wait for socket to appear
    sleep 0.2

    # Send message via socat (standard on Linux/Mac)
    echo "network NOTICE link_up" | socat - UNIX-SENDTO:"$STYLO_SOCK"

    # Give it a moment to write to DB
    sleep 0.2

    result=$(sqlite3 "$STYLO_DB" "SELECT severity FROM logs WHERE source='network';")

    kill $DAEMON_PID
    [ "$result" == "NOTICE" ]
}

@test "compact: cleaning old entries" {
    # Insert an old entry manually
    sqlite3 "$STYLO_DB" "CREATE TABLE IF NOT EXISTS logs (id INTEGER PRIMARY KEY, timestamp DATETIME, source TEXT, severity TEXT, message TEXT);"
    sqlite3 "$STYLO_DB" "INSERT INTO logs (timestamp, source, severity, message) VALUES (datetime('now', '-25 hours'), 'old_src', 'DEBUG', 'old_msg');"

    run ./target/debug/stylo -c
    [ "$status" -eq 0 ]

    count=$(sqlite3 "$STYLO_DB" "SELECT COUNT(*) FROM logs;")
    [ "$count" -eq 0 ]
}

@test "minimal test" {
    run ./target/debug/stylo --help
    [ "$status" -eq 0 ]
}
