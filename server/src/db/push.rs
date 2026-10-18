//! Push: compare-and-swap application of an operation, with idempotence.

use rusqlite::{params, Connection, OptionalExtension};

use crate::config::PROTOCOL_VERSION;
use crate::db::{now_ms, Database, StoredChange};
use crate::error::{AppError, AppResult};
use crate::protocol::{ChangeIn, ChangeOut, PushResponse};

/// Read all changes belonging to one operation, ordered by cursor.
pub(crate) fn load_op_changes(conn: &Connection, op_id: &str) -> AppResult<Vec<StoredChange>> {
    let mut stmt = conn.prepare(
        "SELECT cursor,kind,key,version,value FROM changes WHERE operation_id=?1 ORDER BY cursor ASC",
    )?;
    let rows = stmt.query_map([op_id], |r| {
        Ok(StoredChange {
            cursor: r.get(0)?,
            kind: r.get(1)?,
            key: r.get(2)?,
            version: r.get(3)?,
            value: r
                .get::<_, Option<String>>(4)?
                .and_then(|s| serde_json::from_str(&s).ok()),
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

fn to_out(changes: &[StoredChange]) -> Vec<ChangeOut> {
    changes
        .iter()
        .map(|c| ChangeOut {
            kind: c.kind.clone(),
            key: c.key.clone(),
            version: c.version,
            value: c.value.clone(),
        })
        .collect()
}

impl Database {
    /// Apply an operation atomically (all-or-nothing CAS). Replaying the same
    /// `operation_id` with the same body is idempotent; a different body with
    /// the same id is a conflict.
    pub fn push(
        &self,
        op_id: &str,
        body_hash: &str,
        changes: &[ChangeIn],
    ) -> AppResult<PushResponse> {
        let mut conn = self.lock()?;

        let existing: Option<(String, i64)> = conn
            .query_row(
                "SELECT body_hash,cursor FROM operations WHERE operation_id=?1",
                [op_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((hash, stored_cursor)) = existing {
            if hash != body_hash {
                return Err(AppError::Conflict(
                    "duplicate operation id with different body".into(),
                ));
            }
            let stored = load_op_changes(&conn, op_id)?;
            let cursor = stored.last().map(|c| c.cursor).unwrap_or(stored_cursor);
            return Ok(PushResponse {
                version: PROTOCOL_VERSION,
                cursor,
                changes: to_out(&stored),
            });
        }

        // Reject missing attachment blobs before mutating anything.
        for ch in changes {
            if let Some(atts) = &ch.attachments {
                for a in atts {
                    if !crate::auth::is_hex64(a) {
                        return Err(AppError::BadRequest(
                            "attachment hash must be 64 hex chars".into(),
                        ));
                    }
                    let n: i64 = conn.query_row(
                        "SELECT COUNT(*) FROM blobs WHERE sha256=?1",
                        [a.to_lowercase()],
                        |r| r.get(0),
                    )?;
                    if n == 0 {
                        return Err(AppError::Conflict(format!("missing attachment blob {a}")));
                    }
                }
            }
        }

        let tx = conn.transaction()?;
        let now = now_ms();
        let mut out: Vec<ChangeOut> = Vec::with_capacity(changes.len());
        let mut last_cursor: Option<i64> = None;
        for ch in changes {
            let current: Option<i64> = tx
                .query_row(
                    "SELECT version FROM records WHERE kind=?1 AND key=?2",
                    params![ch.kind, ch.key],
                    |r| r.get(0),
                )
                .optional()?;
            let current = current.unwrap_or(0);
            if current != ch.base_version {
                return Err(AppError::Conflict(format!(
                    "version conflict for {}/{}: server at {} client base {}",
                    ch.kind, ch.key, current, ch.base_version
                )));
            }
            let new_version = current + 1;
            let value_json = match &ch.value {
                Some(v) if !v.is_null() => Some(serde_json::to_string(v)?),
                _ => None,
            };
            tx.execute(
                "INSERT INTO records(kind,key,version,value,updated_ms) VALUES(?1,?2,?3,?4,?5)
                 ON CONFLICT(kind,key) DO UPDATE SET
                   version=excluded.version, value=excluded.value, updated_ms=excluded.updated_ms",
                params![ch.kind, ch.key, new_version, value_json, now],
            )?;
            tx.execute(
                "INSERT INTO changes(operation_id,kind,key,version,value) VALUES(?1,?2,?3,?4,?5)",
                params![op_id, ch.kind, ch.key, new_version, value_json],
            )?;
            last_cursor = Some(tx.last_insert_rowid());
            out.push(ChangeOut {
                kind: ch.kind.clone(),
                key: ch.key.clone(),
                version: new_version,
                value: value_json.and_then(|s| serde_json::from_str(&s).ok()),
            });
        }
        let cursor = match last_cursor {
            Some(c) => c,
            None => tx.query_row("SELECT COALESCE(MAX(cursor),0) FROM changes", [], |r| {
                r.get(0)
            })?,
        };
        tx.execute(
            "INSERT INTO operations(operation_id,body_hash,cursor,created_ms) VALUES(?1,?2,?3,?4)",
            params![op_id, body_hash, cursor, now],
        )?;
        tx.commit()?;

        Ok(PushResponse {
            version: PROTOCOL_VERSION,
            cursor,
            changes: out,
        })
    }
}
