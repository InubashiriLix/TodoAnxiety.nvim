//! SQLite-backed store: generic records, an append-only change log, blob
//! metadata, bearer tokens and leases. One connection guarded by a mutex.

use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use crate::error::{AppError, AppResult};

pub mod blobs;
pub mod leases;
pub mod pull;
pub mod push;

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// A change row as read back from `changes`.
pub struct StoredChange {
    pub cursor: i64,
    pub kind: String,
    pub key: String,
    pub version: i64,
    pub value: Option<serde_json::Value>,
}

/// The server's single SQLite database.
pub struct Database {
    conn: Mutex<Connection>,
    path: PathBuf,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS records (
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  version INTEGER NOT NULL,
  value TEXT,
  updated_ms INTEGER NOT NULL,
  PRIMARY KEY (kind, key)
);
CREATE TABLE IF NOT EXISTS changes (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  operation_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  key TEXT NOT NULL,
  version INTEGER NOT NULL,
  value TEXT
);
CREATE INDEX IF NOT EXISTS idx_changes_operation ON changes(operation_id);
CREATE TABLE IF NOT EXISTS operations (
  operation_id TEXT PRIMARY KEY,
  body_hash TEXT NOT NULL,
  cursor INTEGER NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blobs (
  sha256 TEXT PRIMARY KEY,
  size INTEGER NOT NULL,
  media_type TEXT,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
  token_hash TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  created_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS leases (
  session_id TEXT PRIMARY KEY,
  owner TEXT NOT NULL,
  token_hash TEXT NOT NULL,
  expires_ms INTEGER NOT NULL
);
"#;

impl Database {
    /// Open (creating if needed) the database at `path` and run migrations.
    pub fn open(path: &Path) -> AppResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        let _mode: String = conn.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
        conn.execute_batch("PRAGMA foreign_keys=ON;")?;
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        let db = Database {
            conn: Mutex::new(conn),
            path: path.to_path_buf(),
        };
        db.migrate()?;
        Ok(db)
    }

    /// Path of the underlying database file.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Apply the schema (idempotent).
    pub fn migrate(&self) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute_batch(SCHEMA)?;
        Ok(())
    }

    pub(crate) fn lock(&self) -> AppResult<MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| AppError::Internal("database lock poisoned".into()))
    }

    /// Register a bearer token (by digest) with a human readable label.
    pub fn add_token(&self, token_hash: &str, label: &str) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO tokens(token_hash,label,created_ms) VALUES(?1,?2,?3)
             ON CONFLICT(token_hash) DO UPDATE SET label=excluded.label",
            rusqlite::params![token_hash, label, now_ms()],
        )?;
        Ok(())
    }

    /// True when a token digest is present in the store.
    pub fn token_valid(&self, token_hash: &str) -> AppResult<bool> {
        let conn = self.lock()?;
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM tokens WHERE token_hash=?1",
            [token_hash],
            |r| r.get(0),
        )?;
        Ok(n > 0)
    }

    /// Revoke a token digest. Returns whether a row was removed.
    pub fn revoke_token(&self, token_hash: &str) -> AppResult<bool> {
        let conn = self.lock()?;
        let n = conn.execute("DELETE FROM tokens WHERE token_hash=?1", [token_hash])?;
        Ok(n > 0)
    }

    /// Snapshot the database into `dest` using SQLite `VACUUM INTO`.
    pub fn backup_to(&self, dest: &Path) -> AppResult<()> {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = self.lock()?;
        conn.execute("VACUUM INTO ?1", rusqlite::params![dest.to_string_lossy()])?;
        Ok(())
    }
}
