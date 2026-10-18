//! Static limits, protocol constants and on-disk paths.
//!
//! Everything the server enforces about "how big is too big" lives here so the
//! bounds are auditable in one place. No unbounded request, page or file path
//! exists elsewhere in the crate.

use std::env;
use std::path::{Path, PathBuf};

/// Wire protocol version implemented by this server.
pub const PROTOCOL_VERSION: u32 = 2;

/// Maximum accepted JSON request body (push / leases / anything non-blob).
pub const MAX_JSON_BODY: usize = 4 * 1024 * 1024; // 4 MiB

/// Maximum accepted blob body (raw bytes).
pub const MAX_BLOB_BYTES: usize = 10 * 1024 * 1024; // 10 MiB

/// Hard cap on the number of changes inside a single push operation.
pub const MAX_CHANGES_PER_PUSH: usize = 1000;

/// Default page size (in operations) for `GET /v1/pull`.
pub const DEFAULT_PULL_OPS: usize = 200;

/// Hard cap on a client requested page size (in operations).
pub const MAX_PULL_OPS: usize = 1000;

/// Hard cap on changelog rows materialised by one pull page.
pub const MAX_PULL_ROWS: usize = 5000;

/// Maximum byte length of a record `kind`.
pub const MAX_KIND_LEN: usize = 64;

/// Maximum byte length of a record `key`.
pub const MAX_KEY_LEN: usize = 512;

/// Default lease TTL in seconds when the client does not ask for one.
pub const DEFAULT_LEASE_TTL_SECONDS: i64 = 60;

/// Maximum lease TTL in seconds (24h).
pub const MAX_LEASE_TTL_SECONDS: i64 = 24 * 60 * 60;

/// Server wide configuration resolved from CLI flags / environment.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// Bind address for `serve`.
    pub bind: String,
    /// Optional TLS certificate (PEM).
    pub tls_cert: Option<PathBuf>,
    /// Optional TLS private key (PEM).
    pub tls_key: Option<PathBuf>,
    /// Storage layout.
    pub paths: Paths,
}

impl ServerConfig {
    /// Resolve configuration from explicit flags falling back to env vars and
    /// finally to defaults.
    pub fn resolve(
        data_dir: Option<PathBuf>,
        bind: Option<String>,
        tls_cert: Option<PathBuf>,
        tls_key: Option<PathBuf>,
    ) -> Self {
        let bind = bind
            .or_else(|| env::var("TODOANXIETY_BIND").ok())
            .unwrap_or_else(|| "127.0.0.1:8787".to_string());
        let tls_cert = tls_cert.or_else(|| env::var_os("TODOANXIETY_TLS_CERT").map(PathBuf::from));
        let tls_key = tls_key.or_else(|| env::var_os("TODOANXIETY_TLS_KEY").map(PathBuf::from));
        ServerConfig {
            bind,
            tls_cert,
            tls_key,
            paths: Paths::resolve(data_dir),
        }
    }
}

/// Filesystem layout of a sync server data directory.
#[derive(Debug, Clone)]
pub struct Paths {
    pub data_dir: PathBuf,
    pub db_file: PathBuf,
    pub blob_dir: PathBuf,
    pub backup_dir: PathBuf,
}

impl Paths {
    pub fn resolve(data_dir: Option<PathBuf>) -> Self {
        let data_dir = data_dir
            .or_else(|| env::var_os("TODOANXIETY_DATA_DIR").map(PathBuf::from))
            .unwrap_or_else(default_data_dir);
        Self::from_dir(data_dir)
    }

    pub fn from_dir<P: Into<PathBuf>>(data_dir: P) -> Self {
        let data_dir: PathBuf = data_dir.into();
        Paths {
            db_file: data_dir.join("sync.sqlite3"),
            blob_dir: data_dir.join("blobs"),
            backup_dir: data_dir.join("backups"),
            data_dir,
        }
    }

    /// Create every directory the server needs.
    pub fn ensure(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.data_dir)?;
        std::fs::create_dir_all(self.tmp_dir())?;
        std::fs::create_dir_all(&self.backup_dir)?;
        Ok(())
    }

    /// Directory used for atomic blob staging (same filesystem as `blob_dir`).
    pub fn tmp_dir(&self) -> PathBuf {
        self.blob_dir.join("tmp")
    }

    /// On-disk path of a blob, sharded by the first two hex characters.
    pub fn blob_path(&self, sha256: &str) -> PathBuf {
        let shard = sha256.get(0..2).unwrap_or("00");
        self.blob_dir.join(shard).join(sha256)
    }
}

fn default_data_dir() -> PathBuf {
    if let Some(dir) = env::var_os("XDG_DATA_HOME") {
        return Path::new(&dir).join("todoanxiety-sync");
    }
    if let Some(home) = env::var_os("HOME") {
        return Path::new(&home).join(".local/share/todoanxiety-sync");
    }
    PathBuf::from("./todoanxiety-sync-data")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shards_blob_paths() {
        let p = Paths::from_dir("/tmp/x");
        assert!(p.blob_path("ab12").ends_with("blobs/ab/ab12"));
        assert_eq!(p.db_file, PathBuf::from("/tmp/x/sync.sqlite3"));
    }
}
