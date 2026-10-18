//! Pull: cursor-based change log pages, grouped by operation.

use rusqlite::params;

use crate::config::{MAX_PULL_ROWS, PROTOCOL_VERSION};
use crate::db::{Database, StoredChange};
use crate::error::AppResult;
use crate::protocol::{ChangeOut, PullOperation, PullResponse};

impl Database {
    /// Return up to `limit` *complete* operations whose first change starts
    /// after `after`. The returned `cursor` is the last change actually
    /// returned, so an operation is never split across pages: we first select
    /// whole operation ids and only then materialise their changes, bounded by
    /// [`MAX_PULL_ROWS`]. A single operation is always returned whole; pushes
    /// cap an operation at [`crate::config::MAX_CHANGES_PER_PUSH`] changes.
    pub fn pull(&self, after: i64, limit: usize) -> AppResult<PullResponse> {
        let conn = self.lock()?;

        // Pass 1: pick whole operations in cursor order, stopping before the
        // row budget would be exceeded (but always keeping the first one).
        let mut stmt = conn.prepare(
            "SELECT operation_id, COUNT(*), SUM(length(CAST(COALESCE(value,'') AS BLOB)) + 6*length(CAST(kind AS BLOB)) + 6*length(CAST(key AS BLOB)) + 256) FROM changes
             WHERE cursor > ?1 GROUP BY operation_id
             ORDER BY MIN(cursor) ASC LIMIT ?2",
        )?;
        let candidates = stmt.query_map(params![after, limit as i64], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;

        let budget = MAX_PULL_ROWS as i64;
        let mut selected: Vec<String> = Vec::new();
        let mut rows_used = 0i64;
        let mut bytes_used = 0i64;
        for candidate in candidates {
            let (op_id, count, bytes) = candidate?;
            if !selected.is_empty()
                && (rows_used + count > budget || bytes_used + bytes + 256 > 8 * 1024 * 1024)
            {
                break;
            }
            rows_used += count;
            bytes_used += bytes + 256;
            selected.push(op_id);
        }

        if selected.is_empty() {
            return Ok(PullResponse {
                version: PROTOCOL_VERSION,
                cursor: after,
                operations: Vec::new(),
            });
        }

        // Pass 2: materialise the changes of exactly those operations, whole,
        // in cursor order so the response keeps operations grouped and ordered.
        let placeholders = vec!["?"; selected.len()].join(",");
        let sql = format!(
            "SELECT cursor,operation_id,kind,key,version,value FROM changes
             WHERE operation_id IN ({placeholders}) ORDER BY cursor ASC"
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(selected.iter()), |r| {
            Ok((
                r.get::<_, String>(1)?,
                StoredChange {
                    cursor: r.get(0)?,
                    kind: r.get(2)?,
                    key: r.get(3)?,
                    version: r.get(4)?,
                    value: r
                        .get::<_, Option<String>>(5)?
                        .and_then(|s| serde_json::from_str(&s).ok()),
                },
            ))
        })?;

        let mut operations: Vec<PullOperation> = Vec::with_capacity(selected.len());
        let mut cursor = after;
        for row in rows {
            let (op_id, change) = row?;
            cursor = change.cursor;
            let out = ChangeOut {
                kind: change.kind,
                key: change.key,
                version: change.version,
                value: change.value,
            };
            match operations.last_mut() {
                Some(last) if last.id == op_id => last.changes.push(out),
                _ => operations.push(PullOperation {
                    id: op_id,
                    sequence: change.cursor,
                    changes: vec![out],
                }),
            }
        }

        Ok(PullResponse {
            version: PROTOCOL_VERSION,
            cursor,
            operations,
        })
    }
}
