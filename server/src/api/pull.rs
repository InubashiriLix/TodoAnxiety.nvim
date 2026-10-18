//! `GET /v1/pull`.

use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::Json;

use super::{authenticate, AppState};
use crate::config::{DEFAULT_PULL_OPS, MAX_PULL_OPS};
use crate::error::{AppError, AppResult};
use crate::protocol::{PullQuery, PullResponse};

/// Return a page of operations strictly after `after`.
pub async fn pull(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> AppResult<Json<PullResponse>> {
    authenticate(&state, &headers)?;
    let after = query.after.unwrap_or(0);
    if after < 0 {
        return Err(AppError::BadRequest("after must be >= 0".into()));
    }
    let limit = query
        .limit
        .unwrap_or(DEFAULT_PULL_OPS)
        .clamp(1, MAX_PULL_OPS);
    Ok(Json(state.db.pull(after, limit)?))
}
