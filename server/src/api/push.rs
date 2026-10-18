//! `POST /v1/push`.

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;

use super::{authenticate, AppState};
use crate::config::{
    MAX_CHANGES_PER_PUSH, MAX_JSON_BODY, MAX_KEY_LEN, MAX_KIND_LEN, PROTOCOL_VERSION,
};
use crate::error::{AppError, AppResult};
use crate::protocol::{PushRequest, PushResponse};

/// Validate then apply one operation.
pub async fn push(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> AppResult<Json<PushResponse>> {
    authenticate(&state, &headers)?;
    if body.len() > MAX_JSON_BODY {
        return Err(AppError::PayloadTooLarge);
    }
    let req: PushRequest = serde_json::from_slice(&body)
        .map_err(|e| AppError::BadRequest(format!("invalid push body: {e}")))?;
    if req.version != PROTOCOL_VERSION {
        return Err(AppError::BadRequest("unsupported protocol version".into()));
    }
    if req.operation_id.trim().is_empty() || req.operation_id.len() > 128 {
        return Err(AppError::BadRequest("operation_id is required".into()));
    }
    if req.changes.len() > MAX_CHANGES_PER_PUSH {
        return Err(AppError::BadRequest("too many changes in one push".into()));
    }
    for ch in &req.changes {
        if ch.kind.is_empty() || ch.kind.len() > MAX_KIND_LEN {
            return Err(AppError::BadRequest("invalid change kind".into()));
        }
        if ch.key.is_empty() || ch.key.len() > MAX_KEY_LEN {
            return Err(AppError::BadRequest("invalid change key".into()));
        }
        if ch.base_version < 0 {
            return Err(AppError::BadRequest("base_version must be >= 0".into()));
        }
    }
    let body_hash = crate::auth::sha256_hex(&body);
    let response = state.db.push(&req.operation_id, &body_hash, &req.changes)?;
    Ok(Json(response))
}
