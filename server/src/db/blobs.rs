//! Blob metadata (bytes themselves live on disk, content addressed).

use rusqlite::OptionalExtension;

use crate::db::{now_ms, Database};
use crate::error::AppResult;

impl Database {
    /// Record (or refresh) a stored blob's metadata.
    pub fn record_blob(&self, sha256: &str, size: i64, media_type: Option<&str>) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO blobs(sha256,size,media_type,created_ms) VALUES(?1,?2,?3,?4)
             ON CONFLICT(sha256) DO UPDATE SET size=excluded.size, media_type=excluded.media_type",
            rusqlite::params![sha256, size, media_type, now_ms()],
        )?;
        Ok(())
    }

    /// `(size, media_type)` for a blob, or `None` if unknown.
    pub fn blob_meta(&self, sha256: &str) -> AppResult<Option<(i64, Option<String>)>> {
        let conn = self.lock()?;
        let row = conn
            .query_row(
                "SELECT size,media_type FROM blobs WHERE sha256=?1",
                [sha256],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row)
    }

    /// True when the blob is known to the server.
    pub fn blob_exists(&self, sha256: &str) -> AppResult<bool> {
        Ok(self.blob_meta(sha256)?.is_some())
    }
}
