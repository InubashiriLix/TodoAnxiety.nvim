//! Exclusive, TTL-bounded leases. Any live lease blocks a new acquisition,
//! including one by the same owner — renewal requires presenting the previous
//! token, which protocol v1 never does. An expired lease is freely reusable.

use rusqlite::OptionalExtension;

use crate::auth::{generate_token, sha256_hex};
use crate::db::Database;
use crate::error::AppResult;

/// Result of a lease acquisition attempt.
pub enum AcquireOutcome {
    Granted { token: String, ttl_seconds: i64 },
    Conflict,
}

/// Result of a lease release attempt.
pub enum ReleaseOutcome {
    Released,
    Mismatch,
    Absent,
}

impl Database {
    /// Acquire or renew the lease for `session` for `ttl` seconds.
    ///
    /// A *live* lease (not yet expired) blocks every acquisition, including one
    /// by the same owner: the owner must present the exact token it was given
    /// (`renew_token`) to renew. Protocol v1 never sends a renew token, so any
    /// live lease is a hard conflict and two processes can never both hold it.
    pub fn acquire_lease(
        &self,
        session: &str,
        owner: &str,
        ttl: i64,
        now: i64,
        renew_token: Option<&str>,
    ) -> AppResult<AcquireOutcome> {
        let conn = self.lock()?;
        let existing: Option<(String, String, i64)> = conn
            .query_row(
                "SELECT owner,token_hash,expires_ms FROM leases WHERE session_id=?1",
                [session],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((held_owner, token_hash, expires)) = existing {
            if expires > now {
                let renews = matches!(
                    renew_token,
                    Some(t) if held_owner == owner && token_hash == sha256_hex(t.as_bytes())
                );
                if !renews {
                    return Ok(AcquireOutcome::Conflict);
                }
            }
        }
        let token = renew_token
            .map(str::to_string)
            .unwrap_or_else(generate_token);
        let token_hash = sha256_hex(token.as_bytes());
        let expires_ms = now + ttl.saturating_mul(1000);
        conn.execute(
            "INSERT INTO leases(session_id,owner,token_hash,expires_ms) VALUES(?1,?2,?3,?4)
             ON CONFLICT(session_id) DO UPDATE SET
               owner=excluded.owner, token_hash=excluded.token_hash, expires_ms=excluded.expires_ms",
            rusqlite::params![session, owner, token_hash, expires_ms],
        )?;
        Ok(AcquireOutcome::Granted {
            token,
            ttl_seconds: ttl,
        })
    }

    /// Release a lease, verifying owner and token.
    pub fn release_lease(
        &self,
        session: &str,
        owner: &str,
        token: &str,
        now: i64,
    ) -> AppResult<ReleaseOutcome> {
        let conn = self.lock()?;
        let existing: Option<(String, String, i64)> = conn
            .query_row(
                "SELECT owner,token_hash,expires_ms FROM leases WHERE session_id=?1",
                [session],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        match existing {
            None => Ok(ReleaseOutcome::Absent),
            Some((held_owner, token_hash, expires)) => {
                if expires <= now {
                    conn.execute("DELETE FROM leases WHERE session_id=?1", [session])?;
                    return Ok(ReleaseOutcome::Absent);
                }
                if held_owner != owner || token_hash != sha256_hex(token.as_bytes()) {
                    return Ok(ReleaseOutcome::Mismatch);
                }
                conn.execute("DELETE FROM leases WHERE session_id=?1", [session])?;
                Ok(ReleaseOutcome::Released)
            }
        }
    }
}
