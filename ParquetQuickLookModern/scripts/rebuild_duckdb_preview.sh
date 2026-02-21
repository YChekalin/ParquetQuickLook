#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="com.cheky.parquetquicklook2.host.extension"

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this as your normal user (not root)."
  exit 1
fi

cd "$PROJECT_DIR"

echo "1) Regenerate Xcode project"
xcodegen generate

echo
echo "2) Build signed host + extension (Debug)"
BUILD_LOG="/tmp/pql_build_$(date +%s).log"
if ! xcodebuild -project ParquetQuickLookModern.xcodeproj \
  -scheme ParquetQuickLookHost \
  -configuration Debug \
  build 2>&1 | tee "$BUILD_LOG"; then
  echo
  echo "Build failed. Log: $BUILD_LOG"
  echo "Most relevant compiler lines:"
  rg -n "ParquetPreviewProvider.swift|error:" "$BUILD_LOG" | tail -n 200 || true
  exit 1
fi

echo
echo "3) Pin extension to /Applications"
"/bin/zsh" "$PROJECT_DIR/scripts/pin_quicklook_permanent.sh"

echo
echo "4) Restart Quick Look/Finder"
killall lsd quicklookd QuickLookUIService Finder 2>/dev/null || true

echo
echo "5) Active extension record"
pluginkit -mAvvv -i "$BUNDLE_ID" || true
