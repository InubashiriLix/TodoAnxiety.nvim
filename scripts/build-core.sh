#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cargo build --release --manifest-path "$repo_root/core/Cargo.toml"
printf 'built %s\n' "$repo_root/core/target/release/todo-core"
