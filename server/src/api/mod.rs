//! Axum router, shared state and bearer authentication.

use std::sync::Arc;

use axum::extract::{DefaultBodyLimit, Request, State};
use axum::http::HeaderMap;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Json, Router};

use crate::config::{Paths, MAX_BLOB_BYTES, PROTOCOL_VERSION};
use crate::db::Database;
use crate::error::{AppError, AppResult};
use crate::protocol::StatusResponse;

pub mod blobs;
pub mod leases;
pub mod pull;
pub mod push;

/// State shared by every handler.
pub struct AppState {
    pub db: Database,
    pub paths: Paths,
}

/// Shared, reference-counted application state.
pub type SharedState = Arc<AppState>;

/// Build the protocol v1 router.
pub fn router(state: SharedState) -> Router {
    let private = Router::new()
        .route("/v1/push", post(push::push))
        .route("/v1/pull", get(pull::pull))
        .route(
            "/v1/blobs/{sha256}",
            put(blobs::put_blob).get(blobs::get_blob),
        )
        .route(
            "/v1/leases/{session_id}",
            post(leases::acquire).delete(leases::release),
        )
        .layer(DefaultBodyLimit::max(MAX_BLOB_BYTES + 8192))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth));
    Router::new()
        .route("/v1/status", get(status))
        .merge(private)
        .with_state(state)
}

/// Reject before JSON or Bytes extractors consume an untrusted request body.
async fn require_auth(State(state): State<SharedState>, request: Request, next: Next) -> Response {
    if let Err(error) = authenticate(&state, request.headers()) {
        let mut response = error.into_response();
        response.headers_mut().insert(
            axum::http::header::WWW_AUTHENTICATE,
            axum::http::HeaderValue::from_static("Bearer"),
        );
        return response;
    }
    next.run(request).await
}

/// `GET /v1/status` — unauthenticated health/version probe.
async fn status() -> Json<StatusResponse> {
    Json(StatusResponse {
        version: PROTOCOL_VERSION,
    })
}

/// Verify the `Authorization: Bearer <token>` header against stored digests.
pub(crate) fn authenticate(state: &AppState, headers: &HeaderMap) -> AppResult<()> {
    let token = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|t| !t.is_empty() && t.len() <= 8192)
        .ok_or(AppError::Unauthorized)?;
    let hash = crate::auth::sha256_hex(token.as_bytes());
    if state.db.token_valid(&hash)? {
        Ok(())
    } else {
        Err(AppError::Unauthorized)
    }
}
