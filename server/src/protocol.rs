//! Wire types for protocol v2. All responses carry `version: 2`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `GET /v1/status` response.
#[derive(Debug, Serialize)]
pub struct StatusResponse {
    pub version: u32,
}

/// `POST /v1/push` request body.
#[derive(Debug, Deserialize)]
pub struct PushRequest {
    pub version: u32,
    pub operation_id: String,
    pub changes: Vec<ChangeIn>,
}

/// A single change inside a push. `value == null` is a tombstone.
#[derive(Debug, Deserialize)]
pub struct ChangeIn {
    pub kind: String,
    pub key: String,
    #[serde(default)]
    pub base_version: i64,
    #[serde(default)]
    pub value: Option<Value>,
    #[serde(default)]
    pub attachments: Option<Vec<String>>,
}

/// A change echoed back by push/pull.
#[derive(Debug, Serialize)]
pub struct ChangeOut {
    pub kind: String,
    pub key: String,
    pub version: i64,
    pub value: Option<Value>,
}

/// `POST /v1/push` response body.
#[derive(Debug, Serialize)]
pub struct PushResponse {
    pub version: u32,
    pub cursor: i64,
    pub changes: Vec<ChangeOut>,
}

/// `GET /v1/pull` query parameters.
#[derive(Debug, Deserialize)]
pub struct PullQuery {
    #[serde(default)]
    pub after: Option<i64>,
    #[serde(default)]
    pub limit: Option<usize>,
}

/// One operation as returned by pull (changes grouped by operation).
#[derive(Debug, Serialize)]
pub struct PullOperation {
    pub id: String,
    pub sequence: i64,
    pub changes: Vec<ChangeOut>,
}

/// `GET /v1/pull` response body.
#[derive(Debug, Serialize)]
pub struct PullResponse {
    pub version: u32,
    pub cursor: i64,
    pub operations: Vec<PullOperation>,
}

/// `POST /v1/leases/{session_id}` request body.
#[derive(Debug, Deserialize)]
pub struct LeaseRequest {
    pub owner: String,
    #[serde(default)]
    pub token: Option<String>,
    #[serde(default)]
    pub ttl_seconds: Option<i64>,
}

/// `POST /v1/leases/{session_id}` response body.
#[derive(Debug, Serialize)]
pub struct LeaseResponse {
    pub version: u32,
    pub session_id: String,
    pub owner: String,
    pub token: String,
    pub ttl_seconds: i64,
}

/// `DELETE /v1/leases/{session_id}` request body.
#[derive(Debug, Deserialize)]
pub struct LeaseReleaseRequest {
    pub owner: String,
    pub token: String,
}

/// `PUT /v1/blobs/{sha256}` response body.
#[derive(Debug, Serialize)]
pub struct BlobResponse {
    pub version: u32,
    pub sha256: String,
    pub size: usize,
    pub media_type: Option<String>,
}
