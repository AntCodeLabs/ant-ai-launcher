#!/bin/zsh
# Regenerates the promo screenshots in ../screenshots from the pages in ./pages.
#
# The images are recreations of Clauncher's menu and Settings window with fictional sample data
# ("Sam Rivera" at a made-up "Acme"). The app icon and the shrimp/ant drawings are exported from
# the app's own code first, so the images always match the current icon.
#
# Needs the Command Line Tools and Google Chrome (used headless to render the pages at 2x).
set -euo pipefail
HERE="${0:A:h}"          # resolve before changing directory
ROOT="${HERE:h}"
cd "$HERE"
WORK="$ROOT/build/marketing"
OUT="$ROOT/screenshots"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Google Chrome is needed to render the screenshots." >&2; exit 1; }

rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"
cp pages/* "$WORK/"

# Icon PNG + SVG paths for the shrimp and the ant, straight from Sources/Brand.swift and ShrimpMark.swift.
swiftc -swift-version 5 -o "$WORK/export-marks" \
  "$ROOT/Sources/Brand.swift" "$ROOT/Sources/ShrimpMark.swift" export-marks/main.swift
"$WORK/export-marks" "$WORK"

render() {   # page width height name
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --allow-file-access-from-files --virtual-time-budget=3000 \
    --window-size="$2,$3" --screenshot="$OUT/$4.png" "file://$WORK/$1" >/dev/null 2>&1
  echo "screenshots/$4.png"
}
render 4-title.html   1600 900 clauncher-4-title
render 1-menu.html    1280 900 clauncher-1-menu
render 2-usage.html   1280 900 clauncher-2-usage
render 3-folders.html 1280 900 clauncher-3-folders
