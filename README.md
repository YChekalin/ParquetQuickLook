# Parquet Quick Look (macOS Finder Space Preview)

This project adds Finder Quick Look preview support for `*.parquet` files.

It builds a Quick Look generator bundle (`ParquetQuickLook.qlgenerator`) that:
- recognizes the `.parquet` extension,
- runs a Python helper to read parquet metadata and sample rows,
- renders the result as HTML in Finder Quick Look.

## Requirements

- macOS with Command Line Tools (`clang`, `make`, `qlmanage`)
- Python 3
- `pyarrow` installed in the Python used by `/usr/bin/python3`

Install `pyarrow`:

```bash
/usr/bin/python3 -m pip install --user pyarrow
```

## Build

```bash
make
```

This creates:

```text
ParquetQuickLook.qlgenerator
```

## Install for current user

```bash
make install
```

This copies the generator to:

```text
~/Library/QuickLook/ParquetQuickLook.qlgenerator
```

Then it reloads Quick Look services/cache.

## Test manually

```bash
qlmanage -p /path/to/file.parquet
```

Or in Finder, select a parquet file and press `Space`.

## Uninstall

```bash
make uninstall
```

