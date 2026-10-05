#!/usr/bin/env bash
set -euo pipefail

export NVIM_LOG_FILE="${TODO_NVIM_LOG_FILE:-/tmp/todo-nvim-test.log}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

nvim_data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/nvim"
nui_path="${TODO_NUI_PATH:-$nvim_data_root/lazy/nui.nvim}"
sqlite_path="${TODO_SQLITE_PATH:-$nvim_data_root/lazy/sqlite.lua}"

args=(--clean --headless --cmd "set runtimepath+=$repo_root")
if [[ -d "$nui_path" ]]; then
  args+=(--cmd "set runtimepath+=$nui_path")
fi
if [[ -d "$sqlite_path" ]]; then
  args+=(--cmd "set runtimepath+=$sqlite_path")
fi

nvim "${args[@]}" -l spec/run.lua

if [[ -d "$sqlite_path" ]]; then
  nvim "${args[@]}" -l spec/sync.lua
fi

if [[ -d "$nui_path" ]]; then
  nvim "${args[@]}" --cmd "set columns=140 lines=45" -l spec/wide.lua
fi

if [[ -d "$nui_path" && -d "$sqlite_path" ]]; then
  nvim "${args[@]}" -l spec/smoke.lua
fi
