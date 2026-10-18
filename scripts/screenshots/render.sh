#!/usr/bin/env bash
# Render the README screenshot gallery with VHS.
#
# Usage:
#   scripts/screenshots/render.sh [zh|en] [screen ...]
#
# Requires: vhs, ffmpeg, and a Neovim with the plugin dependencies available.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

lang=${1:-zh}
case "$lang" in
    zh) lang_code="zh-CN" ;;
    en) lang_code="en" ;;
    *)
        echo "usage: $0 [zh|en] [screen ...]" >&2
        exit 2
        ;;
esac
shift || true

default_screens=(
    active
    emergency
    by_urgency
    by_time
    by_tag
    notices
    archived
    today
    plan
    routine_form
    tags
    edit
    notice
    chat
)
screens=("$@")
if ((${#screens[@]} == 0)); then
    screens=("${default_screens[@]}")
fi

command -v vhs >/dev/null || {
    echo "vhs is required: brew install vhs" >&2
    exit 1
}
command -v ffmpeg >/dev/null || {
    echo "ffmpeg is required" >&2
    exit 1
}

demo="$root/scripts/screenshots/.demo"
out="$root/assets/screenshots"
mkdir -p "$demo" "$out"

for screen in "${screens[@]}"; do
    tape="scripts/screenshots/.demo/render-$lang-$screen.tape"
    gif="scripts/screenshots/.demo/render-$lang-$screen.gif"
    png="assets/screenshots/$screen-$lang.png"
    cat >"$tape" <<EOF
Output $gif
Set Shell "bash"
Set FontSize 18
Set FontFamily "JetBrainsMono Nerd Font"
Set Width 1800
Set Height 1100
Set Padding 24
Set Theme "Catppuccin Mocha"
Hide
Type "TODO_DEMO_SCREEN=$screen TODO_DEMO_LANG=$lang_code TODO_DEMO_RESET=1 nvim --clean -u scripts/screenshots/init.lua"
Enter
Sleep 5s
Show
Sleep 2s
EOF
    echo "rendering $screen ($lang)..."
    vhs "$tape" >/dev/null
    ffmpeg -y -sseof -0.15 -i "$gif" -frames:v 1 "$png" -loglevel error
    # Keep the repository light while preserving crisp text.
    if command -v magick >/dev/null; then
        magick "$png" -resize '1600x>' -strip -colors 256 -define png:compression-level=9 "$png"
    fi
    echo "  -> $png"
done
