//! TodoAnxiety.nvim sync server (protocol v1).
//!
//! Store-and-forward sync for generic JSON records plus a change log, raw
//! content-addressed blobs and short-lived exclusive leases. Everything the
//! server accepts is bounded by the constants in [`config`].

pub mod api;
pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod protocol;

pub use config::{Paths, ServerConfig, PROTOCOL_VERSION};
pub use db::Database;
pub use error::{AppError, AppResult};
