#!/bin/zsh
set -euo pipefail

BUNDLE_ID="com.cheky.parquetquicklook2.host.extension"
LEGACY_BUNDLE_ID="com.cheky.parquetquicklook.host.extension"
APP_NAME="ParquetQuickLookHost.app"
APP_EX_NAME="ParquetQuickLookExtension.appex"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LOCAL_DERIVED="$PROJECT_DIR/.DerivedData"
LOGIN_USER="${SUDO_USER:-$USER}"
LOGIN_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" ]]; then
  LOGIN_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' | tail -n1)"
  [[ -n "$LOGIN_HOME" ]] || LOGIN_HOME="/Users/$SUDO_USER"
fi
XCODE_DERIVED="$LOGIN_HOME/Library/Developer/Xcode/DerivedData"

run_as_login_user() {
  if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    local uid
    uid="$(id -u "$SUDO_USER")"
    if command -v launchctl >/dev/null 2>&1; then
      launchctl asuser "$uid" sudo -u "$SUDO_USER" "$@"
    else
      sudo -u "$SUDO_USER" "$@"
    fi
  else
    "$@"
  fi
}

INSTALL_DIR="${1:-$LOGIN_HOME/Applications}"
DEST_APP="$INSTALL_DIR/$APP_NAME"

if [[ ! -x "$LSREG" ]]; then
  echo "lsregister not found at: $LSREG"
  exit 1
fi

typeset -a CANDIDATES
while IFS= read -r p; do CANDIDATES+=("$p"); done < <(
  {
    if [[ -d "$LOCAL_DERIVED" ]]; then
      find "$LOCAL_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME" -exec stat -f '%m %N' {} \; 2>/dev/null
    fi
    if [[ -d "$XCODE_DERIVED" ]]; then
      find "$XCODE_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME" -exec stat -f '%m %N' {} \; 2>/dev/null
    fi
  } | sort -nr | awk '{ $1=""; sub(/^ /, ""); if (!seen[$0]++) print $0 }'
)

team_id_for() {
  local app="$1"
  codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | tail -n1
}

appex_bundle_id_for() {
  local app="$1"
  local appex="$app/Contents/PlugIns/$APP_EX_NAME/Contents/Info.plist"
  [[ -f "$appex" ]] || return 0
  /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$appex" 2>/dev/null || true
}

SRC_APP=""
for app in "${CANDIDATES[@]}"; do
  TEAM_ID="$(team_id_for "$app")"
  APPEX_ID="$(appex_bundle_id_for "$app")"
  [[ "$APPEX_ID" == "$BUNDLE_ID" ]] || continue
  if [[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]]; then
    SRC_APP="$app"
    break
  fi
done

if [[ -z "$SRC_APP" ]]; then
  echo "No trusted signed build found."
  echo "A previous ad-hoc install was likely used and keeps getting rejected by PlugInKit."
  echo "Open Xcode and run scheme 'ParquetQuickLookHost' once, then run this script again."
  exit 2
fi

echo "Using signed build:"
echo "  $SRC_APP"

DEST_APPEX="$DEST_APP/Contents/PlugIns/$APP_EX_NAME"
mkdir -p "$INSTALL_DIR"
if [[ "$INSTALL_DIR" == "/Applications" && "$EUID" -ne 0 ]]; then
  sudo rm -rf "$DEST_APP"
  sudo ditto "$SRC_APP" "$DEST_APP"
elif [[ "$INSTALL_DIR" == "/Applications" && "$EUID" -eq 0 ]]; then
  rm -rf "$DEST_APP"
  ditto "$SRC_APP" "$DEST_APP"
else
  rm -rf "$DEST_APP"
  ditto "$SRC_APP" "$DEST_APP"
fi

# Important: never re-sign with ad-hoc here. It downgrades trust and causes
# PlugInKit to drop the extension ("no matches"/"extension not found").
DEST_TEAM_ID="$(team_id_for "$DEST_APP")"
if [[ -z "$DEST_TEAM_ID" || "$DEST_TEAM_ID" == "not set" ]]; then
  echo "Installed app is ad-hoc signed; refusing to continue."
  echo "Build from Xcode with your Apple Development signing identity first."
  exit 3
fi

DEST_APPEX_ID="$(appex_bundle_id_for "$DEST_APP")"
if [[ "$DEST_APPEX_ID" != "$BUNDLE_ID" ]]; then
  echo "Installed app has wrong extension bundle id: '$DEST_APPEX_ID'"
  echo "Expected: '$BUNDLE_ID'"
  exit 4
fi

# Remove stale registrations from other known copies to avoid path conflicts.
typeset -a STALE_APPEX
if [[ -d "$XCODE_DERIVED" ]]; then
  while IFS= read -r p; do STALE_APPEX+=("$p"); done < <(
    find "$XCODE_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME/Contents/PlugIns/$APP_EX_NAME" 2>/dev/null
  )
fi
if [[ -d "$LOCAL_DERIVED" ]]; then
  while IFS= read -r p; do STALE_APPEX+=("$p"); done < <(
    find "$LOCAL_DERIVED" -type d -path "*/Build/Products/Debug/$APP_NAME/Contents/PlugIns/$APP_EX_NAME" 2>/dev/null
  )
fi
STALE_APPEX+=("$HOME/Applications/$APP_NAME/Contents/PlugIns/$APP_EX_NAME")
STALE_APPEX+=("$LOGIN_HOME/Applications/$APP_NAME/Contents/PlugIns/$APP_EX_NAME")
STALE_APPEX+=("/Applications/$APP_NAME/Contents/PlugIns/$APP_EX_NAME")

for appex in "${STALE_APPEX[@]}"; do
  [[ "$appex" == "$DEST_APPEX" ]] && continue
  [[ -d "$appex" ]] || continue
  run_as_login_user pluginkit -r "$appex" 2>/dev/null || true
done

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  run_as_login_user pluginkit -r "$p" 2>/dev/null || true
done < <(run_as_login_user pluginkit -mAvvv -i "$LEGACY_BUNDLE_ID" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p')
run_as_login_user pluginkit -e ignore -i "$LEGACY_BUNDLE_ID" 2>/dev/null || true

run_as_login_user "$LSREG" -f "$DEST_APP"
run_as_login_user pluginkit -r "$DEST_APPEX" 2>/dev/null || true
PK_ADD_OUT="$(run_as_login_user pluginkit -avvv "$DEST_APPEX" 2>&1 || true)"
run_as_login_user pluginkit -e use -i "$BUNDLE_ID" || true
run_as_login_user pluginkit -e ignore -i "$LEGACY_BUNDLE_ID" 2>/dev/null || true

# Trigger extension discovery for freshly copied host app.
run_as_login_user open -a "$DEST_APP" >/dev/null 2>&1 || true
sleep 1
run_as_login_user killall ParquetQuickLookHost 2>/dev/null || true

run_as_login_user killall lsd quicklookd QuickLookUIService Finder 2>/dev/null || true

echo
echo "Installed to:"
echo "  $DEST_APP"
echo "Registered as user:"
echo "  $LOGIN_USER"
echo
echo "pluginkit record:"
PK_RECORD="$(run_as_login_user pluginkit -mAvvv -i "$BUNDLE_ID" 2>&1 || true)"
echo "$PK_RECORD"

if echo "$PK_RECORD" | grep -q "(no matches)"; then
  echo
  echo "pluginkit -avvv output:"
  echo "$PK_ADD_OUT"

  FALLBACK_DIR="$LOGIN_HOME/Applications"
  FALLBACK_APP="$FALLBACK_DIR/$APP_NAME"
  FALLBACK_APPEX="$FALLBACK_APP/Contents/PlugIns/$APP_EX_NAME"

  if [[ "$INSTALL_DIR" != "$FALLBACK_DIR" ]]; then
    echo
    echo "Retrying with user-level install in: $FALLBACK_DIR"
    run_as_login_user mkdir -p "$FALLBACK_DIR"
    run_as_login_user rm -rf "$FALLBACK_APP"
    run_as_login_user ditto "$SRC_APP" "$FALLBACK_APP"

    run_as_login_user "$LSREG" -f "$FALLBACK_APP"
    run_as_login_user pluginkit -r "$FALLBACK_APPEX" 2>/dev/null || true
    PK_ADD_OUT_FALLBACK="$(run_as_login_user pluginkit -avvv "$FALLBACK_APPEX" 2>&1 || true)"
    run_as_login_user pluginkit -e use -i "$BUNDLE_ID" || true
    run_as_login_user open -a "$FALLBACK_APP" >/dev/null 2>&1 || true
    sleep 1
    run_as_login_user killall ParquetQuickLookHost 2>/dev/null || true
    run_as_login_user killall lsd quicklookd QuickLookUIService Finder 2>/dev/null || true

    echo
    echo "pluginkit -avvv output (user-level retry):"
    echo "$PK_ADD_OUT_FALLBACK"
    echo
    echo "pluginkit record after user-level retry:"
    PK_RECORD="$(run_as_login_user pluginkit -mAvvv -i "$BUNDLE_ID" 2>&1 || true)"
    echo "$PK_RECORD"

    if ! echo "$PK_RECORD" | grep -q "(no matches)"; then
      echo
      echo "Recovered via user-level install:"
      echo "  $FALLBACK_APP"
      exit 0
    fi
  fi

  echo
  echo "ERROR: extension still not registered for user '$LOGIN_USER'."
  echo "Try running this script as your normal user shell (not inside 'sudo su')."
  echo "Recommended:"
  echo "  /bin/zsh $0 \"$LOGIN_HOME/Applications\""
  exit 5
fi

if [[ $# -ge 2 ]]; then
  FILE="$2"
  echo
  echo "UTI for file:"
  run_as_login_user mdls -name kMDItemContentType -name kMDItemContentTypeTree "$FILE" || true
fi
