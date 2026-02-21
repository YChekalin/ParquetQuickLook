#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.cheky.parquetquicklook2.host.extension"
LEGACY_BUNDLE_ID="com.cheky.parquetquicklook.host.extension"
APP_NAME="ParquetQuickLookHost.app"
APPEX_NAME="ParquetQuickLookExtension.appex"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"

DEST_APP="/Applications/$APP_NAME"
DEST_APPEX="$DEST_APP/Contents/PlugIns/$APPEX_NAME"

if [[ "$EUID" -eq 0 ]]; then
  echo "Run this script as your normal user, not root."
  exit 1
fi

if [[ ! -x "$LSREG" ]]; then
  echo "lsregister not found at: $LSREG"
  exit 1
fi

if [[ ! -d "$XCODE_DERIVED" ]]; then
  echo "Xcode DerivedData not found: $XCODE_DERIVED"
  exit 1
fi

team_id_for() {
  local app="$1"
  codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | tail -n1
}

appex_bundle_id_for() {
  local app="$1"
  local plist="$app/Contents/PlugIns/$APPEX_NAME/Contents/Info.plist"
  [[ -f "$plist" ]] || return 0
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true
}

build_marker_for() {
  local app="$1"
  local bin="$app/Contents/PlugIns/$APPEX_NAME/Contents/MacOS/ParquetQuickLookExtension"
  [[ -f "$bin" ]] || return 0
  strings "$bin" 2>/dev/null | sed -n 's/^PQL_BUILD_/PQL_BUILD_/p' | tail -n1
}

typeset -a CANDIDATES
while IFS= read -r p; do CANDIDATES+=("$p"); done < <(
  {
    find "$PROJECT_DIR" -type d -path "*/Build/Products/Debug/$APP_NAME" -exec stat -f '%m %N' {} \; 2>/dev/null
    find "$XCODE_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME" -exec stat -f '%m %N' {} \; 2>/dev/null
  } | sort -nr | awk '{ $1=""; sub(/^ /, ""); if (!seen[$0]++) print $0 }'
)

SRC_APP=""
for app in "${CANDIDATES[@]}"; do
  [[ "$(appex_bundle_id_for "$app")" == "$BUNDLE_ID" ]] || continue
  TEAM_ID="$(team_id_for "$app")"
  [[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]] || continue
  SRC_APP="$app"
  break
done

if [[ -z "$SRC_APP" ]]; then
  echo "No trusted signed build found. Build once in Xcode first."
  exit 2
fi

echo "Using signed build:"
echo "  $SRC_APP"
SRC_MARKER="$(build_marker_for "$SRC_APP")"
if [[ -n "$SRC_MARKER" ]]; then
  echo "  build marker: $SRC_MARKER"
fi

# Remove existing registrations for current extension ID.
typeset -a EXISTING_PATHS
while IFS= read -r p; do EXISTING_PATHS+=("$p"); done < <(
  pluginkit -mAvvv -i "$BUNDLE_ID" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p'
)
for p in "${EXISTING_PATHS[@]}"; do
  [[ -n "$p" ]] || continue
  pluginkit -r "$p" 2>/dev/null || true
done

# Remove and disable legacy extension ID, if present.
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  pluginkit -r "$p" 2>/dev/null || true
done < <(pluginkit -mAvvv -i "$LEGACY_BUNDLE_ID" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p')
pluginkit -e ignore -i "$LEGACY_BUNDLE_ID" 2>/dev/null || true

# Remove stale DerivedData registrations explicitly.
while IFS= read -r p; do
  pluginkit -r "$p" 2>/dev/null || true
done < <(
  find "$XCODE_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME/Contents/PlugIns/$APPEX_NAME" 2>/dev/null
)

# Install pinned copy to /Applications.
sudo rm -rf "$DEST_APP"
sudo ditto "$SRC_APP" "$DEST_APP"
sudo xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

if [[ ! -d "$DEST_APPEX" ]]; then
  echo "Missing extension after copy:"
  echo "  $DEST_APPEX"
  exit 4
fi

DEST_TEAM_ID="$(team_id_for "$DEST_APP")"
if [[ -z "$DEST_TEAM_ID" || "$DEST_TEAM_ID" == "not set" ]]; then
  echo "Copied app has no trusted TeamIdentifier."
  exit 5
fi
if ! codesign --verify --deep "$DEST_APP" >/dev/null 2>&1; then
  echo "Warning: codesign --verify --deep reported issues; continuing with TeamIdentifier=$DEST_TEAM_ID."
fi

DEST_MARKER="$(build_marker_for "$DEST_APP")"
if [[ -n "$DEST_MARKER" ]]; then
  echo "Installed marker:"
  echo "  $DEST_MARKER"
fi

# Keep user-level install from shadowing system install.
rm -rf "$HOME/Applications/$APP_NAME" 2>/dev/null || true

# Restart discovery before registration.
killall lsd quicklookd QuickLookUIService Finder ParquetQuickLookHost 2>/dev/null || true
sleep 1

# Register pinned path.
"$LSREG" -f "$DEST_APP"
pluginkit -r "$DEST_APPEX" 2>/dev/null || true
PK_ADD_OUT="$(pluginkit -avvv "$DEST_APPEX" 2>&1 || true)"
pluginkit -e use -i "$BUNDLE_ID" || true
pluginkit -e ignore -i "$LEGACY_BUNDLE_ID" 2>/dev/null || true

echo
echo "pluginkit -avvv output:"
echo "$PK_ADD_OUT"

# Give LaunchServices time to rebuild records.
typeset -i i=0
RECORD=""
while (( i < 20 )); do
  RECORD="$(pluginkit -mAvvv -i "$BUNDLE_ID" 2>&1 || true)"
  if ! echo "$RECORD" | grep -q "(no matches)"; then
    break
  fi
  sleep 1
  (( i += 1 ))
done

echo
echo "Final pluginkit record:"
echo "$RECORD"

if echo "$RECORD" | grep -q "Path = /Applications/$APP_NAME/Contents/PlugIns/$APPEX_NAME"; then
  echo
  echo "Pinned successfully to /Applications."
  exit 0
fi

echo
echo "Pin failed: active path is not /Applications."
echo "Quit Xcode and run this script again."
exit 3
