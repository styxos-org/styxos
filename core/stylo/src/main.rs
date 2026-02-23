use rusqlite::{params, Connection, Result};
use std::env;
use std::fs;
use std::os::unix::net::UnixDatagram;
use std::process;

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() > 1 && args[1] == "-d" {
        run_daemon()
    } else if args.len() >= 4 {
        run_oneshot(&args[1], &args[2], &args[3])
    } else {
        eprintln!("Usage:");
        eprintln!("  stylo [SOURCE] [SEVERITY] [MESSAGE]");
        eprintln!("  stylo -d    (Startet den Daemon)");
        process::exit(1);
    }
}

fn get_db_path() -> &'static str {
    if cfg!(debug_assertions) { "log.db" } else { "/var/log.db" }
}

fn get_socket_path() -> &'static str {
    if cfg!(debug_assertions) { "log.sock" } else { "/run/log.sock" }
}

fn init_db() -> Result<Connection> {
    let conn = Connection::open(get_db_path())?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.execute("PRAGMA busy_timeout = 5000", [])?; // Wait up to 5 seconds for database write.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            source TEXT NOT NULL,
            severity TEXT NOT NULL,
            message TEXT NOT NULL
        )",
        [],
    )?;
    Ok(conn)
}

fn run_oneshot(source: &str, severity: &str, message: &str) -> Result<()> {
    let conn = init_db()?;
    conn.execute(
        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
        params![source, severity, message],
    )?;
    Ok(())
}

fn run_daemon() -> Result<()> {
    let conn = init_db()?;
    let socket_path = get_socket_path();

    // Cleanup socket
    let _ = fs::remove_file(socket_path);

    let socket = UnixDatagram::bind(socket_path)
        .unwrap_or_else(|e| panic!("Konnte Socket {} nicht binden: {}", socket_path, e));

    println!("Stylo Daemon lauscht auf {}", socket_path);

    let mut buf = [0u8; 4096]; // 4KB Buffer for log lines

    loop {
        // Blocking until a message is received
        match socket.recv_from(&mut buf) {
            Ok((size, _)) => {
                let msg_str = String::from_utf8_lossy(&buf[..size]);
                let msg_trimmed = msg_str.trim();

                // Format parsing: SOURCE SEVERITY MESSAGE
                let parts: Vec<&str> = msg_trimmed.splitn(3, ' ').collect();
                if parts.len() == 3 {
                    let _ = conn.execute(
                        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
                        params![parts[0], parts[1], parts[2]],
                    );
                } else {
                    // Fallback on wrong format
                    let _ = conn.execute(
                        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
                        params!["unknown", "RAW", msg_trimmed],
                    );
                }
            }
            Err(e) => eprintln!("Socket Read Error: {}", e),
        }
    }
}
