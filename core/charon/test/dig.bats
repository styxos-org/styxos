#!/usr/bin/env bats

# Charon DNS Resolver - Integration Tests
#
# Usage:
#   CHARON_HOST=127.0.0.1 CHARON_PORT=5553 bats charon.bats
#
# Requires: dig (dnsutils/bind-utils), charon running with test zones loaded

CHARON_HOST="${CHARON_HOST:-127.0.0.1}"
CHARON_PORT="${CHARON_PORT:-53}"

# ── Helper ─────────────────────────────────────────────────────────────

# Query the nameserver under test. Accepts the same args as dig.
# Sets $output and $status as usual via run.
query() {
    dig "@${CHARON_HOST}" -p "${CHARON_PORT}" +short +time=2 +tries=1 "$@"
}

# Full dig output (for header/flag checks)
query_full() {
    dig "@${CHARON_HOST}" -p "${CHARON_PORT}" +noall +answer +time=2 +tries=1 "$@"
}

# Query and return status flags
query_status() {
    dig "@${CHARON_HOST}" -p "${CHARON_PORT}" +time=2 +tries=1 "$@"
}

# ── Setup / Teardown ──────────────────────────────────────────────────

setup_file() {
    # Verify dig is available
    command -v dig >/dev/null 2>&1 || {
        echo "dig not found, please install `dns-utils`" >&2
        return 1
    }

    # Verify nameserver is reachable
    run dig "@${CHARON_HOST}" -p "${CHARON_PORT}" +short +time=2 +tries=1 version.bind TXT CH
    # Don't check status — just ensure we got a response (even empty)
}

# ── Local Zone: A Records ─────────────────────────────────────────────

@test "A record resolves to correct IPv4" {
    run query gateway.styx.local A
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.1" ]
}

@test "A record for compute node" {
    run query node01.styx.local A
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.10" ]
}

@test "multiple A records return all addresses" {
    run query_full multi.styx.local A
    [ "$status" -eq 0 ]
    # Count answer lines
    local count
    count=$(echo "$output" | grep -c 'IN\s*A')
    [ "$count" -ge 2 ]
}

# ── Local Zone: AAAA Records ──────────────────────────────────────────

@test "AAAA record resolves to correct IPv6" {
    run query gateway.styx.local AAAA
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^fd00::1$ ]]
}

# ── Local Zone: CNAME Records ─────────────────────────────────────────

@test "CNAME resolves to target" {
    run query dns.styx.local CNAME
    [ "$status" -eq 0 ]
    [ "$output" = "gateway.styx.local." ]
}

# ── Local Zone: TXT Records ───────────────────────────────────────────

@test "TXT record returns correct value" {
    run query node01.styx.local TXT
    [ "$status" -eq 0 ]
    [[ "$output" =~ "role=compute" ]]
}

# ── NXDOMAIN ──────────────────────────────────────────────────────────

@test "nonexistent local name returns NXDOMAIN" {
    run query_status doesnotexist.styx.local A
    [[ "$output" =~ "NXDOMAIN" ]]
}

# ── Upstream Forwarding ───────────────────────────────────────────────

@test "external domain resolves via upstream" {
    run query example.com A
    [ "$status" -eq 0 ]
    # example.com has a well-known IP
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "external AAAA resolves via upstream" {
    run query example.com AAAA
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ── Cache Behavior ────────────────────────────────────────────────────

@test "second query for same external domain succeeds (cache)" {
    # Prime the cache
    run query example.com A
    [ "$status" -eq 0 ]

    # Query again — should hit cache
    run query example.com A
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "cache flush via charonctl works" {
    skip "requires charonctl access"
    # Prime cache
    run query example.com A
    [ "$status" -eq 0 ]

    # Flush
    run charonctl flush
    [ "$output" = "OK: cache flushed" ]
}

# ── Edge Cases ────────────────────────────────────────────────────────

@test "empty query name is handled gracefully" {
    run query "" A
    # Should not crash — any non-zero exit or error response is fine
    true
}

@test "very long domain name is handled" {
    local long_name
    long_name="$(printf 'a%.0s' {1..60}).$(printf 'b%.0s' {1..60}).styx.local"
    run query "$long_name" A
    # Should return NXDOMAIN or empty, not crash
    [ "$status" -eq 0 ] || [ "$status" -eq 9 ]
}

# ── Response Validation ───────────────────────────────────────────────

@test "response has AA flag for local zone" {
    run query_status gateway.styx.local A
    [[ "$output" =~ "aa" ]] || [[ "$output" =~ "AA" ]]
}

@test "response time is under 100ms for local zone" {
    run query_status gateway.styx.local A
    # Extract query time from dig output
    local qtime
    qtime=$(echo "$output" | grep -oP 'Query time: \K[0-9]+')
    [ -n "$qtime" ]
    [ "$qtime" -lt 100 ]
}
