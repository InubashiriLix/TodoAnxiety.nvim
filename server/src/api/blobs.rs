//! `PUT`/`GET /v1/blobs/{sha256}` — raw, content-addressed bytes (max 10 MiB).

use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;

use super::{authenticate, AppState};
use crate::config::MAX_BLOB_BYTES;
use crate::error::{AppError, AppResult};
use crate::protocol::BlobResponse;

/// Sniff a small set of image signatures.
pub fn detect_media_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Image signatures the server refuses to store. The client uploads everything
/// as `application/octet-stream`, so the declared content type cannot be
/// trusted: any of these magics is rejected no matter what the header says.
pub fn unsupported_image_magic(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"BM") {
        Some("bmp")
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        Some("tiff")
    } else if bytes.starts_with(&[0x00, 0x00, 0x01, 0x00]) {
        Some("ico")
    } else if bytes.len() >= 12
        && &bytes[4..8] == b"ftyp"
        && matches!(
            &bytes[8..12],
            b"avif" | b"avis" | b"heic" | b"heix" | b"mif1" | b"msf1"
        )
    {
        Some("avif/heif")
    } else {
        None
    }
}

/// Normalise and validate a sha256 path segment.
fn normalize_sha(sha: &str) -> AppResult<String> {
    let sha = sha.to_lowercase();
    if !crate::auth::is_hex64(&sha) {
        return Err(AppError::BadRequest("sha256 must be 64 hex chars".into()));
    }
    Ok(sha)
}

/// Store raw bytes after verifying their hash and any declared image type.
pub async fn put_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(sha): Path<String>,
    body: Bytes,
) -> AppResult<(StatusCode, Json<BlobResponse>)> {
    authenticate(&state, &headers)?;
    let sha = normalize_sha(&sha)?;
    if body.len() > MAX_BLOB_BYTES {
        return Err(AppError::PayloadTooLarge);
    }
    if body.is_empty() {
        return Err(AppError::BadRequest("empty blob".into()));
    }
    let actual = crate::auth::sha256_hex(&body);
    if actual != sha {
        return Err(AppError::BadRequest("sha256 mismatch".into()));
    }
    let media = detect_media_type(&body);
    if media.is_none() {
        return Err(AppError::BadRequest("unsupported image data".into()));
    }
    // Magic-byte gate independent of any declared content type.
    if let Some(fmt) = unsupported_image_magic(&body) {
        return Err(AppError::BadRequest(format!(
            "unsupported image format: {fmt}"
        )));
    }
    if let Some(declared) = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
    {
        if declared.starts_with("image/") {
            match media {
                Some(detected) if declared.starts_with(detected) => {}
                _ => return Err(AppError::BadRequest("invalid image signature".into())),
            }
        }
    }

    let final_path = state.paths.blob_path(&sha);
    let parent = final_path
        .parent()
        .ok_or_else(|| AppError::Internal("bad blob path".into()))?;
    std::fs::create_dir_all(parent)?;
    let tmp = state
        .paths
        .tmp_dir()
        .join(format!("{sha}-{}", crate::auth::generate_token()));
    {
        use std::io::Write;
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(&body)?;
        // Flush to stable storage before the rename makes it visible.
        file.sync_all()?;
    }
    if let Err(e) = std::fs::rename(&tmp, &final_path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    state.db.record_blob(&sha, body.len() as i64, media)?;

    Ok((
        StatusCode::CREATED,
        Json(BlobResponse {
            version: crate::config::PROTOCOL_VERSION,
            sha256: sha,
            size: body.len(),
            media_type: media.map(str::to_string),
        }),
    ))
}

/// Fetch raw bytes for a known blob.
pub async fn get_blob(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(sha): Path<String>,
) -> AppResult<Response> {
    authenticate(&state, &headers)?;
    let sha = normalize_sha(&sha)?;
    let meta = state
        .db
        .blob_meta(&sha)?
        .ok_or_else(|| AppError::NotFound("blob not found".into()))?;
    let bytes = std::fs::read(state.paths.blob_path(&sha))?;
    let media = meta
        .1
        .or_else(|| detect_media_type(&bytes).map(str::to_string))
        .unwrap_or_else(|| "application/octet-stream".to_string());
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, media)
        .body(Body::from(bytes))
        .map_err(AppError::internal)
}
