#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECT_FILE="$PROJECT_DIR/ParquetQuickLookModern.xcodeproj"
PROJECT_SPEC="$PROJECT_DIR/project.yml"
SCHEME="ParquetQuickLookHost"
BUNDLE_ID="com.cheky.parquetquicklook2.host.extension"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this script as your normal macOS user (not root)."
  exit 1
fi

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
}

require_command xcodebuild
require_command pluginkit
require_command qlmanage

if [[ ! -d "$XCODE_DEVELOPER_DIR" ]]; then
  echo "Xcode not found at $XCODE_DEVELOPER_DIR"
  echo "Install Xcode from the App Store first, then rerun."
  exit 1
fi

if [[ "$(xcode-select -p 2>/dev/null || true)" != "$XCODE_DEVELOPER_DIR" ]]; then
  echo "Switching active developer directory to Xcode..."
  sudo xcode-select -s "$XCODE_DEVELOPER_DIR"
fi

if [[ -f "$PROJECT_SPEC" ]] && command -v xcodegen >/dev/null 2>&1; then
  echo "Regenerating Xcode project via xcodegen..."
  (
    cd "$PROJECT_DIR"
    xcodegen generate
  )
fi

if [[ ! -d "$PROJECT_FILE" ]]; then
  echo "Missing project file: $PROJECT_FILE"
  echo "Install xcodegen and run from this project folder:"
  echo "  brew install xcodegen"
  echo "  cd \"$PROJECT_DIR\" && xcodegen generate"
  exit 1
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Eq "Apple Development|Mac Development|Developer ID Application"; then
  echo "No suitable code-signing identity found."
  echo "Open Xcode once, sign in with your Apple ID, then rerun."
  exit 1
fi

BUILD_LOG="/tmp/pql_install_build_$(date +%s).log"
echo "Building signed host + extension (this can take several minutes)..."
if ! xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  build 2>&1 | tee "$BUILD_LOG"; then
  echo
  echo "Build failed. Log: $BUILD_LOG"
  echo "Most relevant lines:"
  grep -En "error:|ParquetPreviewProvider.swift|Signing|CodeSign" "$BUILD_LOG" | tail -n 200 || true
  exit 1
fi

echo
echo "Pinning extension to /Applications and refreshing Finder..."
"/bin/zsh" "$SCRIPT_DIR/pin_quicklook_permanent.sh"

echo
echo "Final active extension:"
pluginkit -mAvvv -i "$BUNDLE_ID" || true

echo
echo "Done. In Finder, select a .parquet file and press Space."
