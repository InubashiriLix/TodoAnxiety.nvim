//! `POST`/`DELETE /v1/leases/{session_id}`.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;

use super::{authenticate, AppState};
use crate::config::{DEFAULT_LEASE_TTL_SECONDS, MAX_LEASE_TTL_SECONDS, PROTOCOL_VERSION};
use crate::db::leases::{AcquireOutcome, ReleaseOutcome};
use crate::db::now_ms;
use crate::error::{AppError, AppResult};
use crate::protocol::{LeaseReleaseRequest, LeaseRequest, LeaseResponse};

/// Acquire (or renew) the exclusive lease on a session.
pub async fn acquire(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(req): Json<LeaseRequest>,
) -> AppResult<Json<LeaseResponse>> {
    authenticate(&state, &headers)?;
    if session_id.trim().is_empty() {
        return Err(AppError::BadRequest("session id is required".into()));
    }
    if req.owner.trim().is_empty() {
        return Err(AppError::BadRequest("owner is required".into()));
    }
    let ttl = req
        .ttl_seconds
        .unwrap_or(DEFAULT_LEASE_TTL_SECONDS)
        .clamp(1, MAX_LEASE_TTL_SECONDS);
    // Protocol v1 carries no renewal token, so any live lease (including one
    // already held by this same owner) is a conflict.
    match state
        .db
        .acquire_lease(&session_id, &req.owner, ttl, now_ms(), req.token.as_deref())?
    {
        AcquireOutcome::Granted { token, ttl_seconds } => Ok(Json(LeaseResponse {
            version: PROTOCOL_VERSION,
            session_id,
            owner: req.owner,
            token,
            ttl_seconds,
        })),
        AcquireOutcome::Conflict => {
            Err(AppError::Conflict("lease is held by another owner".into()))
        }
    }
}

/// Release a lease, verifying both owner and token.
pub async fn release(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(req): Json<LeaseReleaseRequest>,
) -> AppResult<StatusCode> {
    authenticate(&state, &headers)?;
    match state
        .db
        .release_lease(&session_id, &req.owner, &req.token, now_ms())?
    {
        ReleaseOutcome::Released => Ok(StatusCode::NO_CONTENT),
        ReleaseOutcome::Mismatch => Err(AppError::Forbidden("owner or token mismatch".into())),
        ReleaseOutcome::Absent => Err(AppError::NotFound("no active lease".into())),
    }
}
