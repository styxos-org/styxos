<div align="center">
  <img src="logo.png" alt="StyxOS Logo" width="400" />
</div>

# StyxOS

StyxOS is a minimal, completely immutable Linux distribution built from scratch. It is designed to run entirely from a ramdisk, providing a rudimentarily assembled yet highly cohesive environment. 

The core philosophy of StyxOS: **Everything is a database.** It abandons traditional flat-file configurations in favor of a unified SQLite-driven architecture, while still providing a robust OCI-compliant container runtime.


## Key Features

* **100% Immutable & Ramdisk-Based:** The root filesystem is completely ephemeral. A reboot wipes the slate clean, ensuring a pristine state every time.
* **SQLite-Driven State Management:** All persistent data—including configurations, DNS records, system metrics, logs, and shell history—is stored in independent SQLite databases.
* **OCI-Runtime Ready:** Capable of running modern, containerized workloads right out of the box despite its minimal footprint.
* **Modern Tech Stack:** 
*   * System Initialization (PID 1): **Zig**
    * Core Daemons (DNS, Logging, Metrics): **Rust**
    * Tooling & Scripting: **Shell**
* **Zero Bloat:** Statically compiled against `musl` libc. No `systemd`, no legacy init scripts, no unnecessary daemons.

## Architecture

The OS is divided into specialized, mythological-themed components:

* **`init` (Zig):** The PID 1 bare-metal bootstrapper. Mounts the ramdisk, sets up `tmpfs` (e.g., `/run`), and triggers the core daemons.
* **`stylo` (Rust):** The central logging daemon. Listens on a Unix datagram socket (`/run/log.sock`) and writes directly to an attached SQLite WAL database, ensuring zero lock-contention.
* **`charon` (Rust):** The DNS server. Utilizes memory-mapped SQLite databases to resolve queries with ultra-low latency.
* **`pluto` (Rust):** The metrics collection server.

### The Database Hub

Instead of parsing text files in `/etc` or `/var/log`, you query the system state via SQL. The central `core.db` acts as a hub:

```sql
$ sqlite3 /var/core.db
sqlite> ATTACH DATABASE '/var/log.db' AS stylo;
sqlite> ATTACH DATABASE '/var/charon.db' AS charon;
sqlite> SELECT * FROM stylo.logs WHERE severity = 'ERROR';
```

## Building StyxOS

The build process is entirely orchestrated via just. Ensure you have just, the Zig compiler, and the Rust toolchain installed.

```bash
# Clone the repository
git clone [https://github.com/yourusername/styxos.git](https://github.com/yourusername/styxos.git)
cd styxos

# Build the core components (init, stylo, charon, etc.)
just build-core

# Build the complete bootable image
just build-image
```

## Testing

StyxOS relies on the Bash Automated Testing System (BATS) for integration and black-box testing of its core components.


## License

[GPL 3.0](https://www.gnu.org/licenses/gpl-3.0.en.html)
