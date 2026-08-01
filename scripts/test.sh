#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

nvim --clean --headless \
  --cmd "set runtimepath+=$repo_root" \
  -l spec/run.lua
