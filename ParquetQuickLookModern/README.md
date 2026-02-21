# Parquet Quick Look (Modern macOS Extension)

This is a modern Quick Look implementation for Finder (`Space` preview) using:
- a host macOS app
- a Quick Look Preview Extension (`com.apple.quicklook.preview`)

The extension handles `*.parquet` files and renders an HTML preview with:
- file metadata (rows, columns, row groups, size),
- schema,
- sample rows,
- in-preview text search (filters sample rows live).

Rendering is done natively with DuckDB inside the extension (no external `python3` process).

## Requirements

- Xcode 26+ selected with `xcode-select`
- `xcodegen` installed:

```bash
brew install xcodegen
```

## Build

```bash
cd /Users/cheky/Projects/myCodex/ParquetQuickLook/ParquetQuickLookModern
xcodegen generate
xcodebuild -project ParquetQuickLookModern.xcodeproj \
  -scheme ParquetQuickLookHost \
  -configuration Debug \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  build
```

The first build resolves the Swift Package dependency:
- [duckdb-swift](https://github.com/duckdb/duckdb-swift)

One-command rebuild + install + pin:

```bash
/bin/zsh /Users/cheky/Projects/myCodex/ParquetQuickLook/ParquetQuickLookModern/scripts/rebuild_duckdb_preview.sh
```

App output:

```text
build/Build/Products/Debug/ParquetQuickLookHost.app
```

## Install

Copy app to `/Applications` (admin permission required) and run it once:

```bash
sudo ditto build/Build/Products/Debug/ParquetQuickLookHost.app /Applications/ParquetQuickLookHost.app
open /Applications/ParquetQuickLookHost.app
pluginkit -a /Applications/ParquetQuickLookHost.app/Contents/PlugIns/ParquetQuickLookExtension.appex
```

Then refresh Quick Look:

```bash
killall lsd quicklookd QuickLookUIService Finder 2>/dev/null
```

## Verify extension registration

```bash
pluginkit -mAvvv -i com.cheky.parquetquicklook2.host.extension
pluginkit -mAvvv -p com.apple.quicklook.preview | rg -i parquetquicklook
```

If registration still does not appear, open the project in Xcode and set a valid signing team for both targets:
- `ParquetQuickLookHost`
- `ParquetQuickLookExtension`

## Migration package for a new MacBook

Create transfer package:

```bash
/bin/zsh /Users/cheky/Projects/myCodex/ParquetQuickLook/ParquetQuickLookModern/scripts/create_migration_package.sh
```

This writes an archive into:

```text
ParquetQuickLookModern/dist/ParquetQuickLookModern_macos_installer_<timestamp>.tar.gz
```

On the new MacBook:

1. Extract the archive.
2. In Terminal, run `./install.sh` from the extracted folder.

The installer builds signed host+extension and pins it to `/Applications/ParquetQuickLookHost.app`.
