//! `todoanxiety-sync` command line: serve, init, token management, backup.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use todoanxiety_sync::api::{self, AppState};
use todoanxiety_sync::auth::{generate_token, sha256_hex};
use todoanxiety_sync::config::{Paths, ServerConfig};
use todoanxiety_sync::db::{now_ms, Database};

type BoxError = Box<dyn std::error::Error>;

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), BoxError> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        print_usage();
        return Ok(());
    }
    let command = args.remove(0);
    match command.as_str() {
        "help" | "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        "init" => cmd_init(&args),
        "serve" => cmd_serve(&args).await,
        "token" => cmd_token(&args),
        "backup" => cmd_backup(&args),
        other => Err(format!("unknown command: {other}").into()),
    }
}

/// Value following `--name` anywhere in the argument list.
fn take_opt(args: &[String], name: &str) -> Option<String> {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == name {
            return it.next().cloned();
        }
    }
    None
}

fn open_db(args: &[String]) -> Result<(Paths, Database), BoxError> {
    let paths = Paths::resolve(take_opt(args, "--data-dir").map(PathBuf::from));
    paths.ensure()?;
    let db = Database::open(&paths.db_file)?;
    Ok((paths, db))
}

fn cmd_init(args: &[String]) -> Result<(), BoxError> {
    let (paths, _db) = open_db(args)?;
    println!("initialised data directory: {}", paths.data_dir.display());
    println!("database: {}", paths.db_file.display());
    println!("next: todoanxiety-sync token create <label> --data-dir <dir>");
    Ok(())
}

fn cmd_token(args: &[String]) -> Result<(), BoxError> {
    let sub = args.first().map(String::as_str).unwrap_or("");
    match sub {
        "create" => {
            let label = args
                .get(1)
                .cloned()
                .unwrap_or_else(|| "default".to_string());
            let (_, db) = open_db(args)?;
            let token = generate_token();
            db.add_token(&sha256_hex(token.as_bytes()), &label)?;
            println!("{token}");
            eprintln!("token created (label {label}); it is shown only once");
            Ok(())
        }
        "revoke" => {
            let token = if let Some(path) = take_opt(args, "--token-file") {
                use std::io::Read;
                let mut text = String::new();
                std::fs::File::open(path)?
                    .take(8194)
                    .read_to_string(&mut text)?;
                let token = text.trim().to_string();
                if token.is_empty() || token.len() > 8192 {
                    return Err("invalid token file".into());
                }
                token
            } else {
                return Err("usage: token revoke --token-file <private-token-file>".into());
            };
            let (_, db) = open_db(args)?;
            if db.revoke_token(&sha256_hex(token.as_bytes()))? {
                println!("revoked");
            } else {
                eprintln!("no such token");
            }
            Ok(())
        }
        _ => Err("usage: token create <label> | token revoke --token-file <path>".into()),
    }
}

fn cmd_backup(args: &[String]) -> Result<(), BoxError> {
    let (paths, db) = open_db(args)?;
    let out = match take_opt(args, "--out") {
        Some(p) => PathBuf::from(p),
        None => paths.backup_dir.join(format!("backup-{}", now_ms())),
    };

    // Consistency guard: never write the snapshot inside the live blob store.
    std::fs::create_dir_all(&out)?;
    let out_canon = std::fs::canonicalize(&out)?;
    let blob_canon = std::fs::canonicalize(&paths.blob_dir)?;
    if out_canon.starts_with(&blob_canon) {
        return Err(format!(
            "backup --out must not be inside the blob store ({})",
            paths.blob_dir.display()
        )
        .into());
    }

    // Snapshot the database first. Blobs are immutable and never garbage
    // collected, so a database that references them stays consistent with a
    // later blob copy (new blobs are simply copied but unreferenced).
    let db_dest = out.join("sync.sqlite3");
    db.backup_to(&db_dest)?;
    let blobs_dest = out.join("blobs");
    let n = copy_blobs(&paths.blob_dir, &blobs_dest)?;

    println!("backup written to {}", out.display());
    println!("  database: {}", db_dest.display());
    println!("  blobs:    {n} file(s) in {}", blobs_dest.display());
    Ok(())
}

/// Recursively copy the blob store, skipping the `tmp` staging directory.
fn copy_blobs(src: &std::path::Path, dst: &std::path::Path) -> Result<usize, BoxError> {
    if !src.exists() {
        return Ok(0);
    }
    std::fs::create_dir_all(dst)?;
    let mut count = 0;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            if entry.file_name().to_string_lossy() == "tmp" {
                continue;
            }
            count += copy_blobs(&entry.path(), &dst.join(entry.file_name()))?;
        } else if kind.is_file() {
            std::fs::copy(entry.path(), dst.join(entry.file_name()))?;
            count += 1;
        }
    }
    Ok(count)
}

async fn cmd_serve(args: &[String]) -> Result<(), BoxError> {
    let cfg = ServerConfig::resolve(
        take_opt(args, "--data-dir").map(PathBuf::from),
        take_opt(args, "--bind"),
        take_opt(args, "--tls-cert").map(PathBuf::from),
        take_opt(args, "--tls-key").map(PathBuf::from),
    );
    cfg.paths.ensure()?;
    let db = Database::open(&cfg.paths.db_file)?;
    let state = Arc::new(AppState {
        db,
        paths: cfg.paths.clone(),
    });
    let app = api::router(state);
    let addr: SocketAddr = cfg
        .bind
        .parse()
        .map_err(|e| format!("invalid bind address {}: {e}", cfg.bind))?;
    match (cfg.tls_cert.clone(), cfg.tls_key.clone()) {
        (Some(cert), Some(key)) => {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(cert, key).await?;
            println!("listening on https://{addr}");
            axum_server::bind_rustls(addr, tls)
                .serve(app.into_make_service())
                .await?;
        }
        (None, None) => {
            println!("listening on http://{addr}");
            axum_server::bind(addr)
                .serve(app.into_make_service())
                .await?;
        }
        _ => return Err("both --tls-cert and --tls-key are required for TLS".into()),
    }
    Ok(())
}

fn print_usage() {
    println!(
        "todoanxiety-sync {}\n\
         \n\
         USAGE:\n\
           todoanxiety-sync <command> [options]\n\
         \n\
         COMMANDS:\n\
           serve                        Run the sync server\n\
           init                         Create the data directory and database\n\
           token create <label>         Mint a bearer token (printed once)\n\
           token revoke --token-file <path>         Revoke a bearer token\n\
           backup                       Snapshot DB + blobs into a directory\n\
         \n\
         OPTIONS:\n\
           --data-dir <path>            Storage directory\n\
           --bind <addr>                Listen address (serve)\n\
           --tls-cert <pem>             TLS certificate chain (serve)\n\
           --tls-key <pem>              TLS private key (serve)\n\
           --out <dir>                  Backup destination directory (backup)",
        env!("CARGO_PKG_VERSION")
    );
}
