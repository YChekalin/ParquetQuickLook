#!/usr/bin/env python3
import argparse
import html
import os
import traceback


CSS = """
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 24px; color: #1f2937; }
h1 { margin: 0 0 6px 0; font-size: 20px; }
h2 { margin: 20px 0 8px 0; font-size: 16px; }
.meta { color: #4b5563; margin-bottom: 14px; }
table { border-collapse: collapse; width: 100%; font-size: 12px; }
th, td { border: 1px solid #d1d5db; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f3f4f6; position: sticky; top: 0; }
.pill { display: inline-block; background: #eef2ff; color: #3730a3; border-radius: 999px; padding: 2px 10px; margin-right: 8px; font-size: 11px; }
code { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 6px; padding: 1px 6px; }
pre { white-space: pre-wrap; word-break: break-word; background: #111827; color: #f9fafb; padding: 12px; border-radius: 8px; }
"""


def _safe(v):
    if v is None:
        return ""
    return html.escape(str(v))


def _render_error(message: str, details: str = "") -> str:
    details_html = f"<pre>{html.escape(details)}</pre>" if details else ""
    return f"""<!doctype html>
<html>
<head><meta charset="utf-8"><style>{CSS}</style></head>
<body>
  <h1>Parquet Preview Error</h1>
  <p class="meta">{html.escape(message)}</p>
  {details_html}
</body>
</html>
"""


def _render_table(rows, columns):
    header = "".join(f"<th>{_safe(c)}</th>" for c in columns)
    body_parts = []
    for row in rows:
        cells = "".join(f"<td>{_safe(row.get(c))}</td>" for c in columns)
        body_parts.append(f"<tr>{cells}</tr>")
    return f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(body_parts)}</tbody></table>"


def _render_preview(path: str, max_rows: int) -> str:
    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except Exception as exc:
        return _render_error(
            "Missing dependency: pyarrow is required.",
            f"Install with:\n/usr/bin/python3 -m pip install --user pyarrow\n\n{exc}",
        )

    try:
        pf = pq.ParquetFile(path)
        metadata = pf.metadata
        schema = pf.schema_arrow

        columns = list(schema.names)
        sample_rows = []
        for batch in pf.iter_batches(batch_size=max_rows):
            table = pa.Table.from_batches([batch], schema=schema)
            sample_rows = table.to_pylist()
            break

        size_bytes = os.path.getsize(path)
        summary = (
            f'<span class="pill">Rows: {_safe(metadata.num_rows)}</span>'
            f'<span class="pill">Columns: {_safe(metadata.num_columns)}</span>'
            f'<span class="pill">Row Groups: {_safe(metadata.num_row_groups)}</span>'
            f'<span class="pill">Size: {_safe(size_bytes)} bytes</span>'
        )

        schema_lines = []
        for field in schema:
            schema_lines.append(f"{field.name}: {field.type}")
        schema_text = "\n".join(schema_lines)

        table_html = (
            _render_table(sample_rows, columns)
            if sample_rows
            else "<p class='meta'>No rows available in the file.</p>"
        )

        file_name = os.path.basename(path)
        return f"""<!doctype html>
<html>
<head><meta charset="utf-8"><style>{CSS}</style></head>
<body>
  <h1>{_safe(file_name)}</h1>
  <div class="meta"><code>{_safe(path)}</code></div>
  <div>{summary}</div>
  <h2>Schema</h2>
  <pre>{_safe(schema_text)}</pre>
  <h2>Sample Rows (up to {max_rows})</h2>
  {table_html}
</body>
</html>
"""
    except Exception:
        return _render_error("Failed to render parquet preview.", traceback.format_exc())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to parquet file")
    parser.add_argument("--max-rows", type=int, default=100, help="Maximum sample rows")
    args = parser.parse_args()

    print(_render_preview(args.input, args.max_rows))


if __name__ == "__main__":
    main()

