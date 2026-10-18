//! End-to-end tests exercising the protocol through the axum router.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use axum::Router;
use serde_json::{json, Value};
use todoanxiety_sync::api::{self, AppState};
use todoanxiety_sync::auth::sha256_hex;
use todoanxiety_sync::config::Paths;
use todoanxiety_sync::db::Database;
use tower::ServiceExt;

const TOKEN: &str = "test-token-0001";

fn setup() -> (tempfile::TempDir, Router) {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::from_dir(dir.path());
    paths.ensure().unwrap();
    let db = Database::open(&paths.db_file).unwrap();
    db.add_token(&sha256_hex(TOKEN.as_bytes()), "test").unwrap();
    let state = Arc::new(AppState { db, paths });
    (dir, api::router(state))
}

fn json_req(method: &str, uri: &str, body: Value, auth: bool) -> Request<Body> {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if auth {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {TOKEN}"));
    }
    builder.body(Body::from(body.to_string())).unwrap()
}

async fn send(app: &Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), usize::MAX)
        .await
        .unwrap();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, value)
}

async fn send_raw(app: &Router, req: Request<Body>) -> (StatusCode, Vec<u8>) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = axum::body::to_bytes(res.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, bytes.to_vec())
}

#[tokio::test]
async fn status_is_public_and_versioned() {
    let (_dir, app) = setup();
    let (status, body) = send(&app, json_req("GET", "/v1/status", json!({}), false)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["version"], 2);
}

#[tokio::test]
async fn auth_required_for_push() {
    let (_dir, app) = setup();
    let req = json_req(
        "POST",
        "/v1/push",
        json!({"version":2,"operation_id":"op-1","changes":[]}),
        false,
    );
    let (status, _) = send(&app, req).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

fn push_body(op: &str, key: &str, base: i64, value: Value, atts: Option<Value>) -> Value {
    let mut change = json!({"kind":"task","key":key,"base_version":base,"value":value});
    if let Some(a) = atts {
        change["attachments"] = a;
    }
    json!({"version":2,"operation_id":op,"changes":[change]})
}

#[tokio::test]
async fn push_pull_roundtrip_and_cas() {
    let (_dir, app) = setup();
    let (status, body) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("op-1", "task-1", 0, json!({"title":"hi"}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["cursor"], 1);
    assert_eq!(body["changes"][0]["version"], 1);

    // Stale base_version must conflict.
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("op-2", "task-1", 0, json!({"title":"stale"}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    // Correct CAS bump applies.
    let (status, body) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("op-3", "task-1", 1, json!({"title":"new"}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["changes"][0]["version"], 2);

    let (status, body) = send(&app, json_req("GET", "/v1/pull?after=0", json!({}), true)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["cursor"], 2);
    assert_eq!(body["operations"].as_array().unwrap().len(), 2);
    assert_eq!(body["operations"][1]["changes"][0]["version"], 2);
}

#[tokio::test]
async fn duplicate_operation_is_idempotent_or_conflicts() {
    let (_dir, app) = setup();
    let body = push_body("dup", "task-9", 0, json!({"title":"x"}), None);
    let (first_status, first) = send(&app, json_req("POST", "/v1/push", body.clone(), true)).await;
    assert_eq!(first_status, StatusCode::OK);

    // Same body again -> identical response, no new changes.
    let (status, replay) = send(&app, json_req("POST", "/v1/push", body, true)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(replay["cursor"], first["cursor"]);

    // Same id, different body -> conflict.
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("dup", "task-9", 1, json!({"title":"y"}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn blobs_are_content_addressed() {
    let (_dir, app) = setup();
    let bytes = b"\x89PNG\r\n\x1a\nexample".to_vec();
    let sha = sha256_hex(&bytes);

    let put = |sha: &str, body: Vec<u8>| {
        Request::builder()
            .method("PUT")
            .uri(format!("/v1/blobs/{sha}"))
            .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
            .body(Body::from(body))
            .unwrap()
    };

    // Hash mismatch rejected.
    let (status, _) = send_raw(&app, put(&sha, b"different".to_vec())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Correct upload accepted.
    let (status, _) = send_raw(&app, put(&sha, bytes.clone())).await;
    assert_eq!(status, StatusCode::CREATED);

    // Round-trip raw bytes.
    let get = Request::builder()
        .method("GET")
        .uri(format!("/v1/blobs/{sha}"))
        .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
        .body(Body::empty())
        .unwrap();
    let (status, body) = send_raw(&app, get).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, bytes);
}

#[tokio::test]
async fn missing_attachment_blob_is_rejected() {
    let (_dir, app) = setup();
    let bogus = "aa".repeat(32);
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body(
                "op-att",
                "note-1",
                0,
                json!({"body":"x"}),
                Some(json!([bogus])),
            ),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn leases_are_exclusive_with_ttl() {
    let (_dir, app) = setup();
    let body = json!({"owner":"alice","ttl_seconds":30});
    let (status, granted) = send(
        &app,
        json_req("POST", "/v1/leases/sess-1", body.clone(), true),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let token = granted["token"].as_str().unwrap().to_string();

    // Different owner while live -> conflict.
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/leases/sess-1",
            json!({"owner":"bob","ttl_seconds":30}),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    // Wrong token cannot release.
    let (status, _) = send(
        &app,
        json_req(
            "DELETE",
            "/v1/leases/sess-1",
            json!({"owner":"alice","token":"nope"}),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Correct owner+token releases.
    let (status, _) = send(
        &app,
        json_req(
            "DELETE",
            "/v1/leases/sess-1",
            json!({"owner":"alice","token":token}),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn tombstone_records_delete() {
    let (_dir, app) = setup();
    let _ = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("t1", "draft-1", 0, json!({"x":1}), None),
            true,
        ),
    )
    .await;
    let (status, body) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("t2", "draft-1", 1, Value::Null, None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["changes"][0]["version"], 2);
    assert!(body["changes"][0]["value"].is_null());
}

fn multi_change_body(op: &str, changes: Value) -> Value {
    json!({"version":2,"operation_id":op,"changes":changes})
}

#[tokio::test]
async fn cas_conflict_rolls_back_whole_operation() {
    let (_dir, app) = setup();
    // Establish record a at version 1.
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("seed", "a", 0, json!({"n":1}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // One good change (a) and one stale change (b) in the same operation:
    // the whole operation must roll back.
    let body = multi_change_body(
        "roll",
        json!([
            {"kind":"task","key":"a","base_version":1,"value":{"n":2}},
            {"kind":"task","key":"b","base_version":5,"value":{"n":1}}
        ]),
    );
    let (status, _) = send(&app, json_req("POST", "/v1/push", body, true)).await;
    assert_eq!(status, StatusCode::CONFLICT);

    // The rolled-back change for `a` was NOT applied: base_version 1 still wins.
    let (status, body) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("after-a", "a", 1, json!({"n":2}), None),
            true,
        ),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "previous op must have rolled back `a`"
    );
    assert_eq!(body["changes"][0]["version"], 2);

    // `b` was never created either.
    let (status, body) = send(
        &app,
        json_req(
            "POST",
            "/v1/push",
            push_body("after-b", "b", 0, json!({"n":1}), None),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["changes"][0]["version"], 1);
}

async fn push_op_of(app: &Router, op: &str, n: usize) -> StatusCode {
    let changes: Vec<Value> = (0..n)
        .map(|i| json!({"kind":"task","key":format!("{op}-{i}"),"base_version":0,"value":{"i":i}}))
        .collect();
    let (status, _) = send(
        app,
        json_req(
            "POST",
            "/v1/push",
            multi_change_body(op, json!(changes)),
            true,
        ),
    )
    .await;
    status
}

#[tokio::test]
async fn pull_pages_never_split_operations_over_row_budget() {
    let (_dir, app) = setup();
    // 6 operations of 1000 changes each = 6000 rows, over the 5000 row budget.
    for op in 0..6 {
        assert_eq!(
            push_op_of(&app, &format!("bulk-{op}"), 1000).await,
            StatusCode::OK
        );
    }

    let page = |after: i64| {
        let app = app.clone();
        async move {
            let (status, body) = send(
                &app,
                json_req(
                    "GET",
                    &format!("/v1/pull?after={after}&limit=1000"),
                    json!({}),
                    true,
                ),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            body
        }
    };

    let first = page(0).await;
    let ops = first["operations"].as_array().unwrap();
    let rows: usize = ops
        .iter()
        .map(|o| o["changes"].as_array().unwrap().len())
        .sum();
    assert_eq!(rows, 5000, "page must stop at the hard row budget");
    assert_eq!(ops.len(), 5, "budget allows exactly five whole operations");
    assert!(
        ops.iter()
            .all(|o| o["changes"].as_array().unwrap().len() == 1000),
        "no operation may be split across pages"
    );
    assert_eq!(first["cursor"], 5000);

    let second = page(first["cursor"].as_i64().unwrap()).await;
    let ops = second["operations"].as_array().unwrap();
    let rows: usize = ops
        .iter()
        .map(|o| o["changes"].as_array().unwrap().len())
        .sum();
    assert_eq!(ops.len(), 1);
    assert_eq!(rows, 1000);
    assert_eq!(second["cursor"], 6000);
}

#[tokio::test]
async fn blob_rejects_unsupported_image_magic_regardless_of_type() {
    let (_dir, app) = setup();
    let put = |sha: &str, ctype: &str, body: Vec<u8>| {
        Request::builder()
            .method("PUT")
            .uri(format!("/v1/blobs/{sha}"))
            .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
            .header(header::CONTENT_TYPE, ctype)
            .body(Body::from(body))
            .unwrap()
    };

    // A BMP magic uploaded as octet-stream (what the client actually sends).
    let bmp = {
        let mut v = b"BM".to_vec();
        v.extend_from_slice(&[0u8; 30]);
        v
    };
    let (status, _) = send_raw(
        &app,
        put(&sha256_hex(&bmp), "application/octet-stream", bmp),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A supported PNG magic is still accepted under octet-stream.
    let png = {
        let mut v = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        v.extend_from_slice(&[0u8; 16]);
        v
    };
    let (status, _) = send_raw(
        &app,
        put(&sha256_hex(&png), "application/octet-stream", png),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn live_lease_blocks_same_owner_and_204_has_no_body() {
    let (_dir, app) = setup();
    let (status, granted) = send(
        &app,
        json_req(
            "POST",
            "/v1/leases/sess-x",
            json!({"owner":"alice","ttl_seconds":30}),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let token = granted["token"].as_str().unwrap().to_string();

    // The same owner re-acquiring a live lease must conflict (no renew token in v1).
    let (status, _) = send(
        &app,
        json_req(
            "POST",
            "/v1/leases/sess-x",
            json!({"owner":"alice","ttl_seconds":30}),
            true,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);

    // A successful DELETE returns 204 with an empty body and no JSON.
    let req = json_req(
        "DELETE",
        "/v1/leases/sess-x",
        json!({"owner":"alice","token":token}),
        true,
    );
    let (status, body) = send_raw(&app, req).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(body.is_empty(), "204 must not carry a JSON body");
}

#[tokio::test]
async fn all_data_routes_reject_missing_and_wrong_tokens_before_parsing() {
    let (_dir, app) = setup();
    let hash = "a".repeat(64);
    for (method, uri) in [
        ("GET", "/v1/pull".to_string()),
        ("POST", "/v1/push".to_string()),
        ("GET", format!("/v1/blobs/{hash}")),
        ("PUT", format!("/v1/blobs/{hash}")),
        ("POST", "/v1/leases/private-session".to_string()),
        ("DELETE", "/v1/leases/private-session".to_string()),
    ] {
        for token in [None, Some("wrong-token")] {
            let mut request = Request::builder()
                .method(method)
                .uri(&uri)
                .header(header::CONTENT_TYPE, "application/json");
            if let Some(value) = token {
                request = request.header(header::AUTHORIZATION, format!("Bearer {value}"));
            }
            // An invalid JSON body must not get as far as JSON extraction.
            let response = app
                .clone()
                .oneshot(request.body(Body::from("not-json")).unwrap())
                .await
                .unwrap();
            assert_eq!(
                response.status(),
                StatusCode::UNAUTHORIZED,
                "{method} {uri}"
            );
            assert_eq!(
                response.headers().get(header::WWW_AUTHENTICATE).unwrap(),
                "Bearer"
            );
        }
    }
    let oversized = Request::builder()
        .method("POST")
        .uri("/v1/push")
        .body(Body::from(vec![0u8; 11 * 1024 * 1024]))
        .unwrap();
    assert_eq!(
        app.clone().oneshot(oversized).await.unwrap().status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn revoking_a_device_token_blocks_the_next_request() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::from_dir(dir.path());
    paths.ensure().unwrap();
    let db = Database::open(&paths.db_file).unwrap();
    db.add_token(&sha256_hex(TOKEN.as_bytes()), "device")
        .unwrap();
    let state = Arc::new(AppState { db, paths });
    let app = api::router(state.clone());
    assert_eq!(
        send(&app, json_req("GET", "/v1/pull", json!({}), true))
            .await
            .0,
        StatusCode::OK
    );
    assert!(state
        .db
        .revoke_token(&sha256_hex(TOKEN.as_bytes()))
        .unwrap());
    assert_eq!(
        send(&app, json_req("GET", "/v1/pull", json!({}), true))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn internal_errors_do_not_expose_private_details_to_http_clients() {
    use axum::response::IntoResponse;
    let response = todoanxiety_sync::error::AppError::Internal(
        "private filesystem/database details".to_string(),
    )
    .into_response();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let bytes = axum::body::to_bytes(response.into_body(), 1024)
        .await
        .unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("private filesystem"));
}

#[test]
fn cli_revokes_tokens_from_a_private_file_without_a_secret_argument() {
    let dir = tempfile::tempdir().unwrap();
    let bin = env!("CARGO_BIN_EXE_todoanxiety-sync");
    let output = std::process::Command::new(bin)
        .args(["token", "create", "temporary-test", "--data-dir"])
        .arg(dir.path())
        .output()
        .unwrap();
    assert!(output.status.success());
    let token = String::from_utf8(output.stdout).unwrap().trim().to_string();
    assert_eq!(token.len(), 64);
    let file = dir.path().join("private-token");
    std::fs::write(&file, &token).unwrap();
    let revoked = std::process::Command::new(bin)
        .args(["token", "revoke", "--token-file"])
        .arg(&file)
        .arg("--data-dir")
        .arg(dir.path())
        .output()
        .unwrap();
    assert!(revoked.status.success());
    assert!(!String::from_utf8_lossy(&revoked.stdout).contains(&token));
    let db = Database::open(&dir.path().join("sync.sqlite3")).unwrap();
    assert!(!db.token_valid(&sha256_hex(token.as_bytes())).unwrap());
}
