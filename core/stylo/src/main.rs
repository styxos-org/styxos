use rusqlite::{params, Connection, Result};
use std::env;
use std::process;

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();

    if args.len() < 4 {
        eprintln!("Usage: stylo [SOURCE] [SEVERITY] [MESSAGE]");
        process::exit(1);
    }

    let source = &args[1];
    let severity = &args[2];
    let message = &args[3];

    // Compile-time Weiche für den Dateipfad
    let db_path = if cfg!(debug_assertions) {
        "log.db"
    } else {
        "/var/log.db"
    };

    let conn = Connection::open(db_path)?;

    // WAL-Modus für Nebenläufigkeit aktivieren
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

    conn.execute(
        "INSERT INTO logs (source, severity, message) VALUES (?1, ?2, ?3)",
        params![source, severity, message],
    )?;

    Ok(())
}
