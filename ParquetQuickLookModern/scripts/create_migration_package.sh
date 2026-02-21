#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
STAMP="$(date +%Y%m%d_%H%M%S)"
PKG_NAME="ParquetQuickLookModern_macos_installer_${STAMP}"
STAGE_DIR="$DIST_DIR/$PKG_NAME"
PROJECT_STAGE_DIR="$STAGE_DIR/ParquetQuickLookModern"
ARCHIVE_PATH="$DIST_DIR/${PKG_NAME}.tar.gz"

BUILD_MARKER="$(grep -n 'buildMarker = ' "$PROJECT_DIR/Extension/Sources/ParquetPreviewProvider.swift" | sed -E 's/.*\"(PQL_BUILD_[A-Z0-9_]+)\".*/\1/' | head -n 1)"

if command -v xcodegen >/dev/null 2>&1; then
  (
    cd "$PROJECT_DIR"
    xcodegen generate >/dev/null
  )
fi

rm -rf "$STAGE_DIR"
mkdir -p "$PROJECT_STAGE_DIR/scripts"

cp -R "$PROJECT_DIR/App" "$PROJECT_STAGE_DIR/"
cp -R "$PROJECT_DIR/Extension" "$PROJECT_STAGE_DIR/"
cp -R "$PROJECT_DIR/ParquetQuickLookModern.xcodeproj" "$PROJECT_STAGE_DIR/"
cp "$PROJECT_DIR/project.yml" "$PROJECT_STAGE_DIR/"
cp "$PROJECT_DIR/README.md" "$PROJECT_STAGE_DIR/"

cp "$PROJECT_DIR/scripts/install_on_new_mac.sh" "$PROJECT_STAGE_DIR/scripts/"
cp "$PROJECT_DIR/scripts/pin_quicklook_permanent.sh" "$PROJECT_STAGE_DIR/scripts/"
cp "$PROJECT_DIR/scripts/recover_quicklook.sh" "$PROJECT_STAGE_DIR/scripts/"
cp "$PROJECT_DIR/scripts/rebuild_duckdb_preview.sh" "$PROJECT_STAGE_DIR/scripts/"

chmod +x "$PROJECT_STAGE_DIR/scripts/"*.sh

# Remove machine/user-specific Xcode metadata from the portable archive.
rm -rf "$PROJECT_STAGE_DIR/ParquetQuickLookModern.xcodeproj/xcuserdata"
rm -rf "$PROJECT_STAGE_DIR/ParquetQuickLookModern.xcodeproj/project.xcworkspace/xcuserdata"

cat > "$STAGE_DIR/install.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
"/bin/zsh" "$SCRIPT_DIR/ParquetQuickLookModern/scripts/install_on_new_mac.sh"
EOF
chmod +x "$STAGE_DIR/install.sh"

cat > "$STAGE_DIR/INSTALL.md" <<EOF
# Install Parquet Quick Look on a New Mac

Package: $PKG_NAME
Build marker in source: ${BUILD_MARKER:-unknown}

## Steps

1. Extract this archive on the new Mac.
2. Open Terminal in the extracted folder.
3. Run:

\`\`\`bash
./install.sh
\`\`\`

The installer will:

- verify Xcode/toolchain,
- build signed host + extension,
- pin extension to \`/Applications/ParquetQuickLookHost.app\`,
- refresh Finder Quick Look registration.

## Requirements

- Xcode installed in \`/Applications/Xcode.app\`
- Apple Development signing identity available in Keychain (via Xcode login)
- Internet access on first build (fetches duckdb-swift package)

## Verify

\`\`\`bash
pluginkit -mAvvv -i com.cheky.parquetquicklook2.host.extension
\`\`\`

Then preview a \`*.parquet\` file in Finder using Space.
EOF

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
tar -C "$DIST_DIR" -czf "$ARCHIVE_PATH" "$PKG_NAME"
shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"

echo "Created package:"
echo "  $ARCHIVE_PATH"
echo "Checksum:"
cat "$ARCHIVE_PATH.sha256"
