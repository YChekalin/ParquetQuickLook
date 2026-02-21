import AppKit
import DuckDB
import Foundation
import OSLog
import QuickLookUI

@objc(ParquetPreviewProvider)
final class ParquetPreviewProvider: NSViewController, QLPreviewingController, NSSearchFieldDelegate {
    private let logger = Logger(subsystem: "com.cheky.parquetquicklook2.host.extension", category: "preview")
    private let buildMarker = "PQL_BUILD_20260212_DUCKDB_V1"

    private var searchField: NSSearchField!
    private var textView: NSTextView!

    private var headerText = ""
    private var rowLines: [String] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))

        let search = NSSearchField(frame: .zero)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search in sample rows..."
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        self.searchField = search

        let scroll = NSScrollView(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.string = "Loading Parquet preview..."
        self.textView = tv
        scroll.documentView = tv

        root.addSubview(search)
        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            search.heightAnchor.constraint(equalToConstant: 26),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root
    }

    @objc(preparePreviewOfFileAtURL:completionHandler:)
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let content = self.buildContent(for: url)
            DispatchQueue.main.async {
                _ = self.view
                self.headerText = content.header
                self.rowLines = content.rows
                self.applySearchFilter(self.searchField.stringValue)
                handler(nil)
            }
        }
    }

    @objc
    private func searchChanged() {
        applySearchFilter(searchField.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        applySearchFilter(searchField.stringValue)
    }

    private func applySearchFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredRows: [String]
        if trimmed.isEmpty {
            filteredRows = rowLines
        } else {
            let q = trimmed.lowercased()
            filteredRows = rowLines.filter { $0.lowercased().contains(q) }
        }

        var lines: [String] = [headerText]
        lines.append("")
        lines.append("Search query: \(trimmed.isEmpty ? "(none)" : trimmed)")
        lines.append("Matching sample rows: \(filteredRows.count) / \(rowLines.count)")
        lines.append("")
        lines.append("Sample Rows:")

        if filteredRows.isEmpty {
            lines.append("(no matching rows)")
        } else {
            lines.append(contentsOf: filteredRows)
        }

        textView.string = lines.joined(separator: "\n")
    }

    private func buildContent(for fileURL: URL) -> (header: String, rows: [String]) {
        let hasScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let rendererResult = runDuckDBJSONRenderer(fileURL: fileURL)
        if let json = rendererResult.json {
            return buildContentFromJSON(json, fileURL: fileURL)
        }

        return buildFallbackContent(fileURL: fileURL, rendererFailure: rendererResult.failure)
    }

    private func runDuckDBJSONRenderer(fileURL: URL) -> (json: [String: Any]?, failure: String?) {
        let pathLiteral = sqlStringLiteral(fileURL.path)
        let maxRows = 300

        do {
            let database = try Database(store: .inMemory)
            let connection = try database.connect()

            let schemaResult = try connection.query("DESCRIBE SELECT * FROM read_parquet(\(pathLiteral))")
            let columnNames = schemaResult[0].cast(to: String.self)
            let columnTypes = schemaResult[1].cast(to: String.self)

            let schemaCount = min(columnNames.count, columnTypes.count)
            var schema: [[String: Any]] = []
            schema.reserveCapacity(schemaCount)
            for index in 0..<schemaCount {
                let i = DBInt(index)
                schema.append([
                    "name": columnNames[i] ?? "column_\(index)",
                    "type": columnTypes[i] ?? "(unknown)"
                ])
            }

            let countResult = try connection.query("SELECT COUNT(*) AS c FROM read_parquet(\(pathLiteral))")
            let totalRows: Int = {
                if let value = countResult[0].cast(to: Int.self).first ?? nil {
                    return value
                }
                if let value = countResult[0].cast(to: String.self).first ?? nil,
                   let parsed = Int(value) {
                    return parsed
                }
                return 0
            }()

            let rowGroupCount: Int
            do {
                let rowGroupResult = try connection.query(
                    "SELECT COUNT(DISTINCT row_group_id) AS g FROM parquet_metadata(\(pathLiteral))"
                )
                rowGroupCount = {
                    if let value = rowGroupResult[0].cast(to: Int.self).first ?? nil {
                        return value
                    }
                    if let value = rowGroupResult[0].cast(to: String.self).first ?? nil,
                       let parsed = Int(value) {
                        return parsed
                    }
                    return 0
                }()
            } catch {
                rowGroupCount = 0
            }

            let sampleRowsResult = try connection.query(
                "SELECT to_json(t) AS row_json FROM (SELECT * FROM read_parquet(\(pathLiteral)) LIMIT \(maxRows)) AS t"
            )
            let rowJSONStrings = sampleRowsResult[0].cast(to: String.self)

            var rows: [[String: Any]] = []
            rows.reserveCapacity(rowJSONStrings.count)
            for rawMaybe in rowJSONStrings {
                guard let raw = rawMaybe else { continue }
                if let data = raw.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   let row = object as? [String: Any] {
                    rows.append(row)
                } else {
                    rows.append(["_raw": raw])
                }
            }

            let duckDBVersion: String
            if let versionResult = try? connection.query("SELECT version()"),
               let version = versionResult[0].cast(to: String.self).first ?? nil {
                duckDBVersion = version
            } else {
                duckDBVersion = "unknown"
            }

            let payload: [String: Any] = [
                "file_name": fileURL.lastPathComponent,
                "path": fileURL.path,
                "size_bytes": fileSize(fileURL),
                "columns": schema.map { ($0["name"] as? String) ?? "" },
                "schema": schema,
                "rows": rows,
                "metadata": [
                    "num_rows": totalRows,
                    "num_columns": schema.count,
                    "num_row_groups": rowGroupCount
                ],
                "engine": "duckdb",
                "duckdb_version": duckDBVersion
            ]

            return (payload, nil)
        } catch {
            let message = "native parquet renderer failed: \(error.localizedDescription)"
            logger.error("DuckDB renderer failed: \(message, privacy: .public)")
            return (nil, message)
        }
    }

    private func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func buildContentFromJSON(_ json: [String: Any], fileURL: URL) -> (header: String, rows: [String]) {
        let fileName = (json["file_name"] as? String) ?? fileURL.lastPathComponent
        let path = (json["path"] as? String) ?? fileURL.path
        let sizeBytes = (json["size_bytes"] as? NSNumber)?.intValue ?? fileSize(fileURL)

        var lines: [String] = []
        lines.append("File: \(fileName)")
        lines.append("Path: \(path)")
        lines.append("Size: \(sizeBytes) bytes")

        if let metadata = json["metadata"] as? [String: Any] {
            let rows = (metadata["num_rows"] as? NSNumber)?.intValue ?? 0
            let columns = (metadata["num_columns"] as? NSNumber)?.intValue ?? 0
            let groups = (metadata["num_row_groups"] as? NSNumber)?.intValue ?? 0
            lines.append("Rows: \(rows)")
            lines.append("Columns: \(columns)")
            lines.append("Row Groups: \(groups)")
        }

        if let engine = json["engine"] as? String {
            if let version = json["duckdb_version"] as? String {
                lines.append("Engine: \(engine) \(version)")
            } else {
                lines.append("Engine: \(engine)")
            }
        }

        if let error = json["error"] as? String {
            lines.append("")
            lines.append("NOTE: \(error)")
            if let details = json["error_details"] as? String, !details.isEmpty {
                lines.append(details)
            }
        }

        lines.append("")
        lines.append("Schema:")

        if let schema = json["schema"] as? [[String: Any]], !schema.isEmpty {
            for field in schema {
                let name = (field["name"] as? String) ?? "(unknown)"
                let type = (field["type"] as? String) ?? "(unknown)"
                lines.append("- \(name): \(type)")
            }
        } else {
            lines.append("(schema unavailable)")
        }

        var renderedRows: [String] = []
        if let rows = json["rows"] as? [[String: Any]], !rows.isEmpty {
            let columnOrder = (json["columns"] as? [String]) ?? inferColumns(from: rows)
            for (index, row) in rows.enumerated() {
                let parts = columnOrder.map { column in
                    let value = formatValue(row[column])
                    return "\(column)=\(value)"
                }
                renderedRows.append("[\(index + 1)] " + parts.joined(separator: " | "))
            }
        }

        return (lines.joined(separator: "\n"), renderedRows)
    }

    private func buildFallbackContent(fileURL: URL, rendererFailure: String?) -> (header: String, rows: [String]) {
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let head = data.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            let tail = data.suffix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

            var lines: [String] = []
            lines.append("File: \(fileURL.lastPathComponent)")
            lines.append("Build marker: \(buildMarker)")
            lines.append("Path: \(fileURL.path)")
            lines.append("Size: \(data.count) bytes")
            lines.append("Header hex: \(head)")
            lines.append("Tail hex: \(tail)")
            lines.append("")
            if let rendererFailure, !rendererFailure.isEmpty {
                lines.append("Renderer diagnostic: \(rendererFailure)")
            }
            lines.append("NOTE: native parquet renderer unavailable. Showing binary fallback.")
            lines.append("")
            lines.append("Schema:")
            lines.append("(unavailable)")

            let bytes = data.prefix(1024)
            let hexRows = stride(from: 0, to: bytes.count, by: 16).map { offset -> String in
                let chunk = bytes.dropFirst(offset).prefix(16)
                return String(format: "%04X  %@", offset, chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
            }

            return (lines.joined(separator: "\n"), hexRows)
        } catch {
            let lines = [
                "File: \(fileURL.lastPathComponent)",
                "Path: \(fileURL.path)",
                "Read error: \(error.localizedDescription)",
                "",
                "Schema:",
                "(unavailable)"
            ]
            return (lines.joined(separator: "\n"), [])
        }
    }

    private func inferColumns(from rows: [[String: Any]]) -> [String] {
        guard let first = rows.first else { return [] }
        return first.keys.sorted()
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func formatValue(_ value: Any?) -> String {
        guard let value else { return "" }

        switch value {
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return clamp(string)
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array),
               let string = String(data: data, encoding: .utf8) {
                return clamp(string)
            }
            return clamp(String(describing: array))
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let string = String(data: data, encoding: .utf8) {
                return clamp(string)
            }
            return clamp(String(describing: dict))
        default:
            return clamp(String(describing: value))
        }
    }

    private func clamp(_ value: String, limit: Int = 120) -> String {
        if value.count <= limit { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + "..."
    }
}
