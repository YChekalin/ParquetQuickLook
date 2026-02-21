import AppKit
import DuckDB
import Foundation
import OSLog
import QuickLookUI

@objc(ParquetPreviewProvider)
final class ParquetPreviewProvider: NSViewController, QLPreviewingController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let logger = Logger(subsystem: "com.cheky.parquetquicklook2.host.extension", category: "preview")
    private let buildMarker = "PQL_BUILD_20260212_DUCKDB_TABLE_V1"
    private let rowNumberColumnID = NSUserInterfaceItemIdentifier("__row_number__")

    private struct RowRecord {
        let index: Int
        let values: [String: String]
        let searchableText: String
    }

    private struct PreviewContent {
        let header: String
        let columns: [String]
        let rows: [RowRecord]
    }

    private var searchField: NSSearchField!
    private var rowStatusLabel: NSTextField!
    private var headerTextView: NSTextView!
    private var tableView: NSTableView!

    private var allColumns: [String] = []
    private var allRows: [RowRecord] = []
    private var filteredRows: [RowRecord] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 920))

        let search = NSSearchField(frame: .zero)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search in sample rows..."
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        self.searchField = search

        let status = NSTextField(labelWithString: "0 / 0 rows")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .right
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 12)
        self.rowStatusLabel = status

        let headerScroll = NSScrollView(frame: .zero)
        headerScroll.translatesAutoresizingMaskIntoConstraints = false
        headerScroll.hasVerticalScroller = true
        headerScroll.hasHorizontalScroller = false
        headerScroll.autohidesScrollers = true
        headerScroll.borderType = .bezelBorder

        let headerTV = NSTextView(frame: .zero)
        headerTV.isEditable = false
        headerTV.isRichText = false
        headerTV.usesFontPanel = false
        headerTV.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        headerTV.textContainerInset = NSSize(width: 10, height: 8)
        headerTV.string = "Loading Parquet preview..."
        self.headerTextView = headerTV
        headerScroll.documentView = headerTV

        let tableScroll = NSScrollView(frame: .zero)
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder

        let table = NSTableView(frame: .zero)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.delegate = self
        table.dataSource = self
        self.tableView = table
        tableScroll.documentView = table

        root.addSubview(search)
        root.addSubview(status)
        root.addSubview(headerScroll)
        root.addSubview(tableScroll)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -12),
            search.heightAnchor.constraint(equalToConstant: 26),

            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 220),

            headerScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            headerScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headerScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            headerScroll.heightAnchor.constraint(equalToConstant: 210),

            tableScroll.topAnchor.constraint(equalTo: headerScroll.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        self.view = root
    }

    @objc(preparePreviewOfFileAtURL:completionHandler:)
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let content = self.buildContent(for: url)
            DispatchQueue.main.async {
                _ = self.view
                self.headerTextView.string = content.header
                self.allColumns = content.columns
                self.allRows = content.rows
                self.configureTableColumns(content.columns)
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
        if trimmed.isEmpty {
            filteredRows = allRows
        } else {
            let q = trimmed.lowercased()
            filteredRows = allRows.filter { $0.searchableText.contains(q) }
        }

        rowStatusLabel.stringValue = "\(filteredRows.count) / \(allRows.count) rows"
        tableView.reloadData()
    }

    private func configureTableColumns(_ columns: [String]) {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        let numberColumn = NSTableColumn(identifier: rowNumberColumnID)
        numberColumn.title = "#"
        numberColumn.width = 60
        numberColumn.minWidth = 50
        numberColumn.maxWidth = 100
        tableView.addTableColumn(numberColumn)

        for columnName in columns {
            let id = NSUserInterfaceItemIdentifier(columnName)
            let column = NSTableColumn(identifier: id)
            column.title = columnName
            column.width = 220
            column.minWidth = 110
            tableView.addTableColumn(column)
        }

        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredRows.count, let tableColumn else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("cell.\(tableColumn.identifier.rawValue)")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            let newCell = NSTableCellView(frame: .zero)
            newCell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textField.textColor = .labelColor
            newCell.addSubview(textField)
            newCell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -6),
                textField.topAnchor.constraint(equalTo: newCell.topAnchor, constant: 2),
                textField.bottomAnchor.constraint(equalTo: newCell.bottomAnchor, constant: -2)
            ])
            cell = newCell
        }

        let record = filteredRows[row]
        if tableColumn.identifier == rowNumberColumnID {
            cell.textField?.stringValue = String(record.index)
        } else {
            cell.textField?.stringValue = record.values[tableColumn.identifier.rawValue] ?? ""
        }

        return cell
    }

    private func buildContent(for fileURL: URL) -> PreviewContent {
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
            let totalRows = firstInt(from: countResult[0]) ?? 0

            let rowGroupCount: Int
            do {
                let rowGroupResult = try connection.query(
                    "SELECT COUNT(DISTINCT row_group_id) AS g FROM parquet_metadata(\(pathLiteral))"
                )
                rowGroupCount = firstInt(from: rowGroupResult[0]) ?? 0
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

            let duckDBVersion = firstString(from: (try? connection.query("SELECT version()"))?[0]) ?? "unknown"

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

    private func firstInt(from column: Column<Void>) -> Int? {
        let intColumn = column.cast(to: Int.self)
        if let wrapped = intColumn.first, let value = wrapped {
            return value
        }

        let stringColumn = column.cast(to: String.self)
        if let wrapped = stringColumn.first, let value = wrapped, let parsed = Int(value) {
            return parsed
        }

        return nil
    }

    private func firstString(from column: Column<Void>?) -> String? {
        guard let column else { return nil }
        let stringColumn = column.cast(to: String.self)
        if let wrapped = stringColumn.first, let value = wrapped {
            return value
        }
        return nil
    }

    private func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func buildContentFromJSON(_ json: [String: Any], fileURL: URL) -> PreviewContent {
        let fileName = (json["file_name"] as? String) ?? fileURL.lastPathComponent
        let path = (json["path"] as? String) ?? fileURL.path
        let sizeBytes = (json["size_bytes"] as? NSNumber)?.intValue ?? fileSize(fileURL)

        var lines: [String] = []
        lines.append("File: \(fileName)")
        lines.append("Build marker: \(buildMarker)")
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

        let columnOrder: [String]
        let rowRecords: [RowRecord]
        if let rows = json["rows"] as? [[String: Any]], !rows.isEmpty {
            columnOrder = (json["columns"] as? [String]) ?? inferColumns(from: rows)
            rowRecords = rows.enumerated().map { offset, row in
                var values: [String: String] = [:]
                values.reserveCapacity(columnOrder.count)
                var searchParts: [String] = []
                for column in columnOrder {
                    let text = formatValue(row[column])
                    values[column] = text
                    if !text.isEmpty {
                        searchParts.append(text.lowercased())
                    }
                }
                return RowRecord(index: offset + 1, values: values, searchableText: searchParts.joined(separator: " "))
            }
        } else {
            columnOrder = []
            rowRecords = []
        }

        return PreviewContent(header: lines.joined(separator: "\n"), columns: columnOrder, rows: rowRecords)
    }

    private func buildFallbackContent(fileURL: URL, rendererFailure: String?) -> PreviewContent {
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

            let rows = hexRows.enumerated().map { offset, line in
                RowRecord(index: offset + 1, values: ["Hex": line], searchableText: line.lowercased())
            }
            return PreviewContent(header: lines.joined(separator: "\n"), columns: ["Hex"], rows: rows)
        } catch {
            let lines = [
                "File: \(fileURL.lastPathComponent)",
                "Path: \(fileURL.path)",
                "Read error: \(error.localizedDescription)",
                "",
                "Schema:",
                "(unavailable)"
            ]
            return PreviewContent(header: lines.joined(separator: "\n"), columns: ["Error"], rows: [])
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

    private func clamp(_ value: String, limit: Int = 240) -> String {
        if value.count <= limit { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + "..."
    }
}
