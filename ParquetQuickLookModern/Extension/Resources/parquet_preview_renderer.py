#!/usr/bin/env python3
import argparse
import html
import json
import math
import os
import traceback


CSS = """
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; color: #0f172a; background: #f8fafc; }
.wrap { max-width: 1200px; margin: 0 auto; padding: 18px 24px 24px 24px; }
h1 { margin: 0 0 6px 0; font-size: 24px; letter-spacing: 0.2px; }
h2 { margin: 20px 0 10px 0; font-size: 16px; color: #1e293b; }
.muted { color: #64748b; font-size: 13px; margin-bottom: 14px; }
.cards { display: grid; grid-template-columns: repeat(4, minmax(120px, 1fr)); gap: 8px; margin-bottom: 14px; }
.card { background: #e2e8f0; border: 1px solid #cbd5e1; border-radius: 10px; padding: 8px 10px; font-size: 12px; }
.card b { display: block; font-size: 17px; line-height: 1.2; margin-top: 2px; color: #0f172a; }
.toolbar { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
input[type=text] { width: 360px; max-width: 50vw; border: 1px solid #cbd5e1; border-radius: 8px; padding: 6px 10px; font-size: 13px; background: white; }
.status { color: #475569; font-size: 12px; }
table { border-collapse: collapse; width: 100%; font-size: 12px; background: white; border: 1px solid #cbd5e1; border-radius: 8px; overflow: hidden; }
th, td { border-bottom: 1px solid #e2e8f0; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f1f5f9; position: sticky; top: 0; font-weight: 600; z-index: 1; }
tbody tr:nth-child(even) td { background: #fcfdff; }
tbody tr:hover td { background: #eef6ff; }
.table-wrap { border: 1px solid #cbd5e1; border-radius: 8px; overflow: auto; max-height: 56vh; background: white; }
code { background: #eff6ff; border: 1px solid #bfdbfe; border-radius: 6px; padding: 1px 6px; }
pre { white-space: pre-wrap; word-break: break-word; background: #0f172a; color: #f8fafc; padding: 12px; border-radius: 8px; font-size: 12px; border: 1px solid #334155; }
.hint { color: #64748b; font-size: 12px; margin-top: 6px; }
"""


def _safe(v):
    if v is None:
        return ""
    return html.escape(str(v))


def _to_jsonable(value):
    if value is None:
        return None
    if isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, float):
        if math.isnan(value):
            return "NaN"
        if math.isinf(value):
            return "Infinity" if value > 0 else "-Infinity"
        return value
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (list, tuple)):
        return [_to_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _to_jsonable(v) for k, v in value.items()}
    return str(value)


def _format_value(value):
    value = _to_jsonable(value)
    if value is None:
        return ""
    if isinstance(value, (dict, list, tuple)):
        text = json.dumps(value, ensure_ascii=False)
    else:
        text = str(value)
    if len(text) > 300:
        return text[:297] + "..."
    return text


def _collect_preview_data(path: str, max_rows: int) -> dict:
    data = {
        "file_name": os.path.basename(path),
        "path": path,
        "size_bytes": os.path.getsize(path) if os.path.exists(path) else 0,
        "columns": [],
        "schema": [],
        "rows": [],
        "metadata": {},
    }

    try:
        import pyarrow as pa
        import pyarrow.parquet as pq
    except Exception as exc:
        data["error"] = "Missing dependency: pyarrow is required."
        data["error_details"] = f"Install with:\n/usr/bin/python3 -m pip install --user pyarrow\n\n{exc}"
        return data

    try:
        pf = pq.ParquetFile(path)
        metadata = pf.metadata
        schema = pf.schema_arrow

        data["pyarrow_version"] = getattr(pa, "__version__", "unknown")
        data["metadata"] = {
            "num_rows": int(metadata.num_rows),
            "num_columns": int(metadata.num_columns),
            "num_row_groups": int(metadata.num_row_groups),
        }
        data["columns"] = list(schema.names)
        data["schema"] = [{"name": field.name, "type": str(field.type)} for field in schema]

        rows = []
        batch_size = max(1, min(max_rows, 500))
        for batch in pf.iter_batches(batch_size=batch_size):
            table = pa.Table.from_batches([batch], schema=schema)
            for row in table.to_pylist():
                rows.append({k: _to_jsonable(v) for k, v in row.items()})
                if len(rows) >= max_rows:
                    break
            if len(rows) >= max_rows:
                break
        data["rows"] = rows
    except Exception:
        data["error"] = "Failed to render parquet preview."
        data["error_details"] = traceback.format_exc()

    return data


def _render_error_html(message: str, details: str = "") -> str:
    details_html = f"<pre>{html.escape(details)}</pre>" if details else ""
    return f"""<!doctype html>
<html>
<head><meta charset=\"utf-8\"><style>{CSS}</style></head>
<body>
  <div class=\"wrap\">
    <h1>Parquet Preview Error</h1>
    <p class=\"muted\">{html.escape(message)}</p>
    {details_html}
  </div>
</body>
</html>
"""


def _render_schema_table(schema):
    body = []
    for field in schema:
        body.append(f"<tr><td>{_safe(field.get('name'))}</td><td><code>{_safe(field.get('type'))}</code></td></tr>")
    return f"<table><thead><tr><th>Column</th><th>Type</th></tr></thead><tbody>{''.join(body)}</tbody></table>"


def _render_rows_table(rows, columns):
    header = "<th>#</th>" + "".join(f"<th>{_safe(c)}</th>" for c in columns)
    body = []
    for idx, row in enumerate(rows, start=1):
        cells = "".join(f"<td>{_safe(_format_value(row.get(c)))}</td>" for c in columns)
        body.append(f"<tr><td>{idx}</td>{cells}</tr>")
    return f"<table id='rowsTable'><thead><tr>{header}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def _render_html(data: dict, max_rows: int) -> str:
    if data.get("error"):
        return _render_error_html(data.get("error", "Unknown error"), data.get("error_details", ""))

    metadata = data.get("metadata", {})
    rows = data.get("rows", [])
    schema = data.get("schema", [])
    columns = data.get("columns", [])

    summary = f"""
    <div class=\"cards\">
      <div class=\"card\">Rows<b>{_safe(metadata.get('num_rows', 0))}</b></div>
      <div class=\"card\">Columns<b>{_safe(metadata.get('num_columns', 0))}</b></div>
      <div class=\"card\">Row Groups<b>{_safe(metadata.get('num_row_groups', 0))}</b></div>
      <div class=\"card\">Size (bytes)<b>{_safe(data.get('size_bytes', 0))}</b></div>
    </div>
    """

    table_html = _render_rows_table(rows, columns) if rows else "<p class='muted'>(no rows)</p>"

    return f"""<!doctype html>
<html>
<head><meta charset=\"utf-8\"><style>{CSS}</style></head>
<body>
  <div class=\"wrap\">
    <h1>{_safe(data.get('file_name', 'Parquet'))}</h1>
    <div class=\"muted\"><code>{_safe(data.get('path', ''))}</code> | pyarrow {_safe(data.get('pyarrow_version', 'unknown'))}</div>
    {summary}
    <h2>Schema</h2>
    {_render_schema_table(schema)}
    <h2>Sample Rows (up to {max_rows})</h2>
    <div class=\"toolbar\">
      <input id=\"searchBox\" type=\"text\" placeholder=\"Search in sample rows...\" />
      <span id=\"rowStatus\" class=\"status\"></span>
    </div>
    <div class=\"table-wrap\">{table_html}</div>
    <div class=\"hint\">Search filters only the sampled rows shown in this preview.</div>
  </div>
  <script>
  (function() {{
    const input = document.getElementById("searchBox");
    const table = document.getElementById("rowsTable");
    const status = document.getElementById("rowStatus");
    if (!input || !table || !status) return;
    const rows = Array.from(table.tBodies[0].rows);
    const update = () => {{
      const q = input.value.trim().toLowerCase();
      let visible = 0;
      rows.forEach((row) => {{
        const show = !q || row.textContent.toLowerCase().includes(q);
        row.style.display = show ? "" : "none";
        if (show) visible += 1;
      }});
      status.textContent = `${{visible}} / ${{rows.length}} rows shown`;
    }};
    input.addEventListener("input", update);
    update();
  }})();
  </script>
</body>
</html>
"""


def _render_text(data: dict, max_rows: int) -> str:
    lines = [
        f"File: {data.get('file_name', '')}",
        f"Path: {data.get('path', '')}",
        f"Size: {data.get('size_bytes', 0)} bytes",
    ]

    metadata = data.get("metadata", {})
    if metadata:
        lines.append(f"Rows: {metadata.get('num_rows', 0)}")
        lines.append(f"Columns: {metadata.get('num_columns', 0)}")
        lines.append(f"Row Groups: {metadata.get('num_row_groups', 0)}")

    if data.get("error"):
        lines.append("")
        lines.append(f"ERROR: {data.get('error')}")
        details = data.get("error_details", "")
        if details:
            lines.append(details)

    lines.append("")
    lines.append("Schema:")
    schema = data.get("schema", [])
    if schema:
        for field in schema:
            lines.append(f"- {field.get('name')}: {field.get('type')}")
    else:
        lines.append("(schema unavailable)")

    lines.append("")
    lines.append(f"Sample Rows (up to {max_rows}):")
    rows = data.get("rows", [])
    columns = data.get("columns", [])
    for idx, row in enumerate(rows, start=1):
        parts = [f"{c}={_format_value(row.get(c))}" for c in columns]
        lines.append(f"[{idx}] " + " | ".join(parts))

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to parquet file")
    parser.add_argument("--max-rows", type=int, default=100, help="Maximum sample rows")
    parser.add_argument("--format", choices=["html", "json", "text"], default="html")
    parser.add_argument("--output", help="Optional output file path")
    args = parser.parse_args()

    data = _collect_preview_data(args.input, args.max_rows)

    if args.format == "json":
        rendered = json.dumps(data, ensure_ascii=False)
    elif args.format == "text":
        rendered = _render_text(data, args.max_rows)
    else:
        rendered = _render_html(data, args.max_rows)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(rendered)
    else:
        print(rendered)


if __name__ == "__main__":
    main()
