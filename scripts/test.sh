#!/usr/bin/env bash
set -euo pipefail

export NVIM_LOG_FILE="${TODO_NVIM_LOG_FILE:-/tmp/todo-nvim-test.log}"
export TODO_DISABLE_LOCAL_AI=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required: todo.nvim has a mandatory Rust core" >&2
  exit 1
fi
cargo build --quiet --manifest-path "$repo_root/core/Cargo.toml"
export TODO_CORE_BIN="${TODO_CORE_BIN:-$repo_root/core/target/debug/todo-core}"

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

if command -v python3 >/dev/null; then
  python3 spec/http_stream.py
fi
nvim "${args[@]}" -l spec/stream.lua
nvim "${args[@]}" -l spec/core.lua
nvim "${args[@]}" -l spec/providers.lua
nvim "${args[@]}" -l spec/ai_markdown.lua
nvim "${args[@]}" -l spec/task_mark.lua
nvim "${args[@]}" -l spec/run.lua
nvim "${args[@]}" -l spec/postpone.lua
nvim "${args[@]}" -l spec/context_actions.lua
nvim "${args[@]}" -l spec/undo.lua
nvim "${args[@]}" -l spec/sync_progress.lua
nvim "${args[@]}" -l spec/network_ui.lua
nvim "${args[@]}" -l spec/config_security.lua
nvim "${args[@]}" -l spec/daily_contrast.lua
nvim "${args[@]}" -l spec/assets_ui.lua

if [[ -d "$sqlite_path" ]]; then
  nvim "${args[@]}" -l spec/sync.lua
  nvim "${args[@]}" -l spec/long_context.lua
  nvim "${args[@]}" -l spec/routines.lua
  nvim "${args[@]}" -l spec/merge.lua
  nvim "${args[@]}" -l spec/capture.lua
  nvim "${args[@]}" -l spec/planning_features.lua
  nvim "${args[@]}" -l spec/ai_references.lua
  nvim "${args[@]}" -l spec/daily.lua
  nvim "${args[@]}" -l spec/ai_permissions.lua
  nvim "${args[@]}" -l spec/ai_understanding.lua
  nvim "${args[@]}" -l spec/ai_recovery.lua
  if [[ -x "${TODO_SERVER_BIN:-$repo_root/server/target/debug/todoanxiety-sync}" ]]; then
    nvim "${args[@]}" -l spec/cloud.lua
  fi
fi

if [[ -d "$nui_path" ]]; then
  nvim "${args[@]}" -l spec/postpone_ui.lua
  nvim "${args[@]}" -l spec/context_ui.lua
  nvim "${args[@]}" --cmd "set columns=140 lines=45" -l spec/wide.lua
fi

if [[ -d "$nui_path" && -d "$sqlite_path" ]]; then
  nvim "${args[@]}" -l spec/history_ui.lua
  nvim "${args[@]}" --cmd "set columns=140 lines=45" -l spec/planner_ui.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/redesign.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/daily_ui.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/daily_note.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/daily_skip_question.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/card_bars.lua
  nvim "${args[@]}" --cmd "set columns=120 lines=45" -l spec/today_operator.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/daily_flow.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/daily_recovery_ui.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/editor_commands.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/panel_navigation.lua
  nvim "${args[@]}" --cmd "set columns=160 lines=50" -l spec/performance.lua
  nvim "${args[@]}" -l spec/smoke.lua
  if command -v python3 >/dev/null && python3 -c 'import msgpack' 2>/dev/null; then
    python3 spec/editor_input.py
  fi
fi
