use rusqlite::{params, Connection, Result};
use std::env;
use std::fs;
use std::os::unix::net::UnixDatagram;
use std::process;

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() > 1 {
        match args[1].as_str() {
            "-d" | "--daemon" => return run_daemon(),
            "-c" | "--compact" => return run_cleanup(),
            "-h" | "--help" => {
                print_usage();
                process::exit(0);
            }
            _ => {
                if args.len() >= 4 {
                    return run_oneshot(&args[1], &args[2], &args[3]);
                }
            }
        }
    }

    print_usage();
    process::exit(1);
}

fn print_usage() {
    eprintln!("Stylo - StyxOS Logging Utility");
    eprintln!("\nUsage:");
    eprintln!("  stylo [SOURCE] [SEVERITY] [MESSAGE]    Log a single message");
    eprintln!("  stylo -d / --daemon                    Start the logging daemon");
    eprintln!("  stylo -c / --compact                   Clean logs > 24h and VACUUM database");
}

fn get_db_path() -> String {
    if cfg!(debug_assertions) {
        std::env::var("STYLO_DB").unwrap_or_else(|_| "log.db".to_string())
    } else {
        "/var/log.db".to_string()
    }
}

fn get_socket_path() -> String {
    if cfg!(debug_assertions) {
        std::env::var("STYLO_SOCK").unwrap_or_else(|_| "log.sock".to_string())
    } else {
        "/run/log.sock".to_string()
    }
}

fn init_db() -> Result<Connection> {
    let conn = Connection::open(get_db_path())?;
    // Set busy timeout to handle concurrent writes from oneshot calls
    conn.pragma_update(None, "busy_timeout", "5000")?;
    conn.pragma_update(None, "journal_mode", "WAL")?;

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

fn run_cleanup() -> Result<()> {
    let db_path = get_db_path();
    println!("Starting database maintenance: {}", db_path);

    let conn = init_db()?;

    // 1. Delete logs older than 24 hours
    let deleted = conn.execute(
        "DELETE FROM logs WHERE timestamp < datetime('now', '-24 hours')",
        [],
    )?;
    println!("Deleted {} old log entries.", deleted);

    // 2. Reclaim disk space
    println!("Running VACUUM...");
    conn.execute("VACUUM", [])?;

    println!("Maintenance complete.");
    Ok(())
}

fn run_daemon() -> Result<()> {
    let conn = init_db()?;
    let socket_path = get_socket_path(); // Dies ist nun ein String

    // Wir übergeben eine Referenz (&), damit wir die Ownership behalten
    let _ = fs::remove_file(&socket_path);

    // Auch hier binden wir per Referenz
    let socket = UnixDatagram::bind(&socket_path)
        .unwrap_or_else(|e| {
            // Da wir oben nur geliehen haben, ist socket_path hier noch verfügbar
            panic!("Could not bind socket {}: {}", socket_path, e)
        });

    println!("Stylo daemon listening on {}", socket_path);

    let mut buf = [0u8; 4096];
    loop {
        match socket.recv_from(&mut buf) {
            Ok((size, _)) => {
                let msg_str = String::from_utf8_lossy(&buf[..size]);
                let msg_trimmed = msg_str.trim();

                let parts: Vec<&str> = msg_trimmed.splitn(3, ' ').collect();
                if parts.len() == 3 {
                    let _ = conn.execute(
                        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
                        params![parts[0], parts[1], parts[2]],
                    );
                } else {
                    let _ = conn.execute(
                        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
                        params!["unknown", "RAW", msg_trimmed],
                    );
                }
            }
            Err(e) => eprintln!("Socket read error: {}", e),
        }
    }
}
