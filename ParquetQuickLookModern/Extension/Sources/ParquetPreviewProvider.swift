import AppKit
import DuckDB
import Foundation
import OSLog
import QuickLookUI

@objc(ParquetPreviewProvider)
final class ParquetPreviewProvider: NSViewController, QLPreviewingController, NSTableViewDataSource, NSTableViewDelegate {
    private let logger = Logger(subsystem: "com.cheky.parquetquicklook2.host.extension", category: "preview")
    private let buildMarker = "PQL_BUILD_20260212_DUCKDB_TABLE_V6_LAYOUT_BUTTONS"
    private let rowNumberColumnID = NSUserInterfaceItemIdentifier("__row_number__")
    private let layoutStoreDefaultsKey = "ParquetQuickLook.TableLayout.BySchema.v1"

    private struct RowRecord {
        let index: Int
        let values: [String: String]
        let rawValues: [String: Any]
        let searchableText: String
    }

    private struct PreviewContent {
        let header: String
        let columns: [String]
        let rows: [RowRecord]
    }

    private struct PersistedTableLayout: Codable {
        let order: [String]
        let widths: [String: Double]
    }

    private var detailsToggleButton: NSButton!
    private var rememberColumnsButton: NSButton!
    private var resetColumnsButton: NSButton!
    private var headerScrollView: NSScrollView!
    private var headerTextView: NSTextView!
    private var tableView: NSTableView!
    private var headerHeightConstraint: NSLayoutConstraint?

    private var allColumns: [String] = []
    private var allRows: [RowRecord] = []
    private var filteredRows: [RowRecord] = []
    private var detailsExpanded = false
    private var currentSchemaSignature = ""
    private var applyingPersistedLayout = false
    private var rememberFeedbackWorkItem: DispatchWorkItem?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 920))

        let detailsButton = NSButton(title: "Show Details", target: self, action: #selector(toggleDetails))
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.bezelStyle = .rounded
        self.detailsToggleButton = detailsButton

        let resetButton = NSButton(title: "Reset Columns", target: self, action: #selector(resetColumnsLayout))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        self.resetColumnsButton = resetButton

        let rememberButton = NSButton(title: "Remember Columns", target: self, action: #selector(rememberColumnsLayout))
        rememberButton.translatesAutoresizingMaskIntoConstraints = false
        rememberButton.bezelStyle = .rounded
        self.rememberColumnsButton = rememberButton

        let headerScroll = NSScrollView(frame: .zero)
        headerScroll.translatesAutoresizingMaskIntoConstraints = false
        headerScroll.hasVerticalScroller = true
        headerScroll.hasHorizontalScroller = false
        headerScroll.autohidesScrollers = true
        headerScroll.borderType = .bezelBorder
        headerScroll.isHidden = true
        self.headerScrollView = headerScroll

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
        table.intercellSpacing = NSSize(width: 2, height: 2)
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsTypeSelect = true
        table.delegate = self
        table.dataSource = self
        self.tableView = table
        tableScroll.documentView = table

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableColumnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: table
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableColumnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        root.addSubview(detailsButton)
        root.addSubview(resetButton)
        root.addSubview(rememberButton)
        root.addSubview(headerScroll)
        root.addSubview(tableScroll)

        let headerHeight = headerScroll.heightAnchor.constraint(equalToConstant: 0)
        self.headerHeightConstraint = headerHeight

        NSLayoutConstraint.activate([
            detailsButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            detailsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            detailsButton.heightAnchor.constraint(equalToConstant: 26),
            detailsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            resetButton.centerYAnchor.constraint(equalTo: detailsButton.centerYAnchor),
            resetButton.leadingAnchor.constraint(equalTo: detailsButton.trailingAnchor, constant: 8),
            resetButton.heightAnchor.constraint(equalToConstant: 26),
            resetButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),

            rememberButton.centerYAnchor.constraint(equalTo: detailsButton.centerYAnchor),
            rememberButton.leadingAnchor.constraint(equalTo: resetButton.trailingAnchor, constant: 8),
            rememberButton.heightAnchor.constraint(equalToConstant: 26),
            rememberButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            headerScroll.topAnchor.constraint(equalTo: detailsButton.bottomAnchor, constant: 6),
            headerScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headerScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            headerHeight,

            tableScroll.topAnchor.constraint(equalTo: headerScroll.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tableScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])

        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateDetailsVisibility()
        adjustPreferredPreviewSize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
                self.currentSchemaSignature = self.schemaSignature(for: content.columns)
                self.configureTableColumns(content.columns)
                self.refreshRows()
                self.updateDetailsVisibility()
                handler(nil)
            }
        }
    }

    @objc
    private func toggleDetails() {
        detailsExpanded.toggle()
        updateDetailsVisibility()
    }

    @objc
    private func resetColumnsLayout() {
        guard !allColumns.isEmpty else { return }
        clearPersistedLayout(for: currentSchemaSignature)
        configureTableColumns(allColumns)
        refreshRows()
    }

    @objc
    private func rememberColumnsLayout() {
        guard !allColumns.isEmpty else {
            NSSound.beep()
            return
        }
        persistCurrentLayoutIfPossible()
        showRememberedFeedback()
    }

    private func updateDetailsVisibility() {
        let expandedHeight = measuredHeaderHeight()
        detailsToggleButton.title = detailsExpanded ? "Hide Details" : "Show Details"
        headerScrollView.isHidden = !detailsExpanded
        headerHeightConstraint?.constant = detailsExpanded ? expandedHeight : 0
        adjustPreferredPreviewSize()
    }

    private func refreshRows() {
        filteredRows = allRows
        sortFilteredRows()
        tableView.reloadData()
        adjustPreferredPreviewSize()
    }

    private func configureTableColumns(_ columns: [String]) {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        let numberColumn = NSTableColumn(identifier: rowNumberColumnID)
        numberColumn.title = "#"
        numberColumn.width = 46
        numberColumn.minWidth = 38
        numberColumn.maxWidth = 72
        numberColumn.sortDescriptorPrototype = NSSortDescriptor(key: rowNumberColumnID.rawValue, ascending: true)
        tableView.addTableColumn(numberColumn)

        for columnName in columns {
            let id = NSUserInterfaceItemIdentifier(columnName)
            let column = NSTableColumn(identifier: id)
            column.title = columnName
            column.width = suggestedColumnWidth(for: columnName)
            column.minWidth = 64
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: columnName,
                ascending: true,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )
            tableView.addTableColumn(column)
        }

        applyPersistedLayoutIfNeeded(columns: columns)

        tableView.sortDescriptors = []
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
                textField.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 3),
                textField.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -3),
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

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortFilteredRows()
        tableView.reloadData()
        adjustPreferredPreviewSize()
    }

    @objc
    private func tableColumnDidMove(_ notification: Notification) {
        persistCurrentLayoutIfPossible()
    }

    @objc
    private func tableColumnDidResize(_ notification: Notification) {
        persistCurrentLayoutIfPossible()
    }

    @objc func copy(_ sender: Any?) {
        guard !filteredRows.isEmpty else {
            NSSound.beep()
            return
        }

        var rowIndexes = tableView.selectedRowIndexes
        if rowIndexes.isEmpty, tableView.selectedRow >= 0 {
            rowIndexes.insert(tableView.selectedRow)
        }
        guard !rowIndexes.isEmpty else {
            NSSound.beep()
            return
        }

        let columnIndexes: [Int]
        if tableView.selectedColumnIndexes.isEmpty {
            columnIndexes = Array(0..<tableView.numberOfColumns)
        } else {
            columnIndexes = Array(tableView.selectedColumnIndexes)
        }

        var lines: [String] = []
        let header = columnIndexes.map { sanitizeForClipboard(tableView.tableColumns[$0].title) }
        lines.append(header.joined(separator: "\t"))

        for row in rowIndexes {
            let cells = columnIndexes.map { column in
                sanitizeForClipboard(copyValue(row: row, column: column))
            }
            lines.append(cells.joined(separator: "\t"))
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
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
                var rawValues: [String: Any] = [:]
                values.reserveCapacity(columnOrder.count)
                rawValues.reserveCapacity(columnOrder.count)
                var searchParts: [String] = []
                for column in columnOrder {
                    let raw = row[column] ?? NSNull()
                    let text = formatValue(raw)
                    values[column] = text
                    rawValues[column] = raw
                    if !text.isEmpty {
                        searchParts.append(text.lowercased())
                    }
                }
                return RowRecord(
                    index: offset + 1,
                    values: values,
                    rawValues: rawValues,
                    searchableText: searchParts.joined(separator: " ")
                )
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
                RowRecord(
                    index: offset + 1,
                    values: ["Hex": line],
                    rawValues: ["Hex": line],
                    searchableText: line.lowercased()
                )
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

    private func schemaSignature(for columns: [String]) -> String {
        columns.joined(separator: "\u{1f}")
    }

    private func loadLayoutStore() -> [String: PersistedTableLayout] {
        guard let data = UserDefaults.standard.data(forKey: layoutStoreDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: PersistedTableLayout].self, from: data)) ?? [:]
    }

    private func saveLayoutStore(_ store: [String: PersistedTableLayout]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: layoutStoreDefaultsKey)
    }

    private func clearPersistedLayout(for signature: String) {
        guard !signature.isEmpty else { return }
        var store = loadLayoutStore()
        store.removeValue(forKey: signature)
        saveLayoutStore(store)
    }

    private func persistCurrentLayoutIfPossible() {
        guard !applyingPersistedLayout else { return }
        guard !currentSchemaSignature.isEmpty else { return }
        guard tableView.numberOfColumns > 1 else { return }

        let columns = tableView.tableColumns.filter { $0.identifier != rowNumberColumnID }
        guard !columns.isEmpty else { return }

        let order = columns.map { $0.identifier.rawValue }
        let widths = Dictionary(
            uniqueKeysWithValues: columns.map { ($0.identifier.rawValue, Double($0.width)) }
        )

        var store = loadLayoutStore()
        store[currentSchemaSignature] = PersistedTableLayout(order: order, widths: widths)
        saveLayoutStore(store)
    }

    private func showRememberedFeedback() {
        rememberFeedbackWorkItem?.cancel()
        rememberColumnsButton.title = "Remembered"
        let work = DispatchWorkItem { [weak self] in
            self?.rememberColumnsButton.title = "Remember Columns"
        }
        rememberFeedbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func applyPersistedLayoutIfNeeded(columns: [String]) {
        guard !currentSchemaSignature.isEmpty else { return }
        let store = loadLayoutStore()
        guard let layout = store[currentSchemaSignature] else { return }

        let available = Set(columns)
        var desiredOrder = layout.order.filter { available.contains($0) }
        for column in columns where !desiredOrder.contains(column) {
            desiredOrder.append(column)
        }

        applyingPersistedLayout = true
        defer { applyingPersistedLayout = false }

        for (targetIndex, columnName) in desiredOrder.enumerated() {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == columnName }) else {
                continue
            }
            let actualTarget = targetIndex + 1 // Keep row number column pinned at index 0.
            if currentIndex != actualTarget {
                tableView.moveColumn(currentIndex, toColumn: actualTarget)
            }
        }

        for column in tableView.tableColumns where column.identifier != rowNumberColumnID {
            guard let storedWidth = layout.widths[column.identifier.rawValue] else { continue }
            let width = max(column.minWidth, CGFloat(storedWidth))
            column.width = min(width, 500)
        }
    }

    private func sortFilteredRows() {
        let descriptors = tableView.sortDescriptors
        guard !descriptors.isEmpty else {
            filteredRows.sort { $0.index < $1.index }
            return
        }

        filteredRows.sort { lhs, rhs in
            for descriptor in descriptors {
                guard let key = descriptor.key else { continue }

                let comparison: ComparisonResult
                if key == rowNumberColumnID.rawValue {
                    comparison = compareInts(lhs.index, rhs.index)
                } else {
                    comparison = compareSortValues(
                        lhs.rawValues[key] ?? NSNull(),
                        rhs.rawValues[key] ?? NSNull()
                    )
                }

                if comparison != .orderedSame {
                    if descriptor.ascending {
                        return comparison == .orderedAscending
                    }
                    return comparison == .orderedDescending
                }
            }
            return lhs.index < rhs.index
        }
    }

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareSortValues(_ lhs: Any, _ rhs: Any) -> ComparisonResult {
        let lhsNull = lhs is NSNull
        let rhsNull = rhs is NSNull
        if lhsNull && rhsNull { return .orderedSame }
        if lhsNull { return .orderedDescending }
        if rhsNull { return .orderedAscending }

        if let left = numericSortValue(lhs), let right = numericSortValue(rhs) {
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        }

        let leftText = textSortValue(lhs)
        let rightText = textSortValue(rhs)
        return leftText.localizedStandardCompare(rightText)
    }

    private func numericSortValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func textSortValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: array),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let dict = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func suggestedColumnWidth(for columnName: String) -> CGFloat {
        let columnCount = max(allColumns.count, 1)
        let veryWide = columnCount >= 40
        let wide = columnCount >= 24

        let sampleLimit = veryWide ? 60 : 100
        let headerCap = veryWide ? 22 : (wide ? 28 : 36)
        let valueCap = veryWide ? 26 : (wide ? 34 : 56)
        let charWidth: CGFloat = veryWide ? 5.2 : (wide ? 5.8 : 6.6)
        let padding: CGFloat = veryWide ? 10 : 14
        let minWidth: CGFloat = veryWide ? 62 : (wide ? 72 : 88)
        let maxWidth: CGFloat = veryWide ? 165 : (wide ? 210 : 320)

        let sample = allRows.prefix(sampleLimit)
        var maxChars = min(columnName.count, headerCap)
        for row in sample {
            let value = row.values[columnName] ?? ""
            maxChars = max(maxChars, min(value.count, valueCap))
        }
        let estimated = CGFloat(maxChars) * charWidth + padding
        return min(max(estimated, minWidth), maxWidth)
    }

    private func copyValue(row: Int, column: Int) -> String {
        guard row >= 0, row < filteredRows.count, column >= 0, column < tableView.numberOfColumns else { return "" }
        let tableColumn = tableView.tableColumns[column]
        if tableColumn.identifier == rowNumberColumnID {
            return String(filteredRows[row].index)
        }
        return filteredRows[row].values[tableColumn.identifier.rawValue] ?? ""
    }

    private func sanitizeForClipboard(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func adjustPreferredPreviewSize() {
        let screenFrame = (view.window?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)

        let maxWidth = max(900, screenFrame.width - 48)
        let maxHeight = max(620, screenFrame.height - 72)

        let headerHeight = detailsExpanded ? measuredHeaderHeight() : 0
        headerHeightConstraint?.constant = headerHeight

        let columnsWidth = tableView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
        let desiredWidth = max(1100, columnsWidth + 48)

        let visibleRows = min(max(filteredRows.count, 12), 30)
        let desiredHeight = 10 + 26 + 6 + headerHeight + 8 + CGFloat(visibleRows) * tableView.rowHeight + 76

        let bounded = NSSize(
            width: min(desiredWidth, maxWidth),
            height: min(desiredHeight, maxHeight)
        )

        preferredContentSize = bounded
        guard let window = view.window else { return }

        let current = window.contentView?.bounds.size ?? .zero
        let target = NSSize(
            width: min(maxWidth, max(current.width, bounded.width)),
            height: min(maxHeight, max(current.height, bounded.height))
        )

        if abs(target.width - current.width) > 1 || abs(target.height - current.height) > 1 {
            window.setContentSize(target)
        }
    }

    private func measuredHeaderHeight() -> CGFloat {
        let headerLines = max(headerTextView.string.split(separator: "\n").count, 8)
        return min(max(CGFloat(headerLines) * 17 + 18, 180), 320)
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
