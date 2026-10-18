//! Error type shared by the database and HTTP layers.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

/// Every failure the server can surface. Mapped to an HTTP status and a small
/// JSON error envelope so clients can branch on the status code alone.
#[derive(Debug)]
pub enum AppError {
    Unauthorized,
    Forbidden(String),
    NotFound(String),
    Conflict(String),
    BadRequest(String),
    PayloadTooLarge,
    Internal(String),
}

impl AppError {
    /// Wrap any displayable error as an opaque internal failure.
    pub fn internal<E: std::fmt::Display>(e: E) -> Self {
        AppError::Internal(e.to_string())
    }
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AppError::Unauthorized => write!(f, "unauthorized"),
            AppError::Forbidden(m)
            | AppError::NotFound(m)
            | AppError::Conflict(m)
            | AppError::BadRequest(m)
            | AppError::Internal(m) => write!(f, "{m}"),
            AppError::PayloadTooLarge => write!(f, "payload too large"),
        }
    }
}

impl std::error::Error for AppError {}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg): (StatusCode, String) = match self {
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".into()),
            AppError::Forbidden(m) => (StatusCode::FORBIDDEN, m),
            AppError::NotFound(m) => (StatusCode::NOT_FOUND, m),
            AppError::Conflict(m) => (StatusCode::CONFLICT, m),
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            AppError::PayloadTooLarge => {
                (StatusCode::PAYLOAD_TOO_LARGE, "payload too large".into())
            }
            AppError::Internal(m) => {
                tracing::error!(error = %m, "internal request failure");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal server error".into(),
                )
            }
        };
        (status, axum::Json(json!({"version": crate::config::PROTOCOL_VERSION, "error": msg}))).into_response()
    }
}

impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        AppError::Internal(format!("database error: {e}"))
    }
}

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        AppError::Internal(format!("io error: {e}"))
    }
}

impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        AppError::BadRequest(format!("invalid json: {e}"))
    }
}

/// Convenience alias used across the crate.
pub type AppResult<T> = Result<T, AppError>;
