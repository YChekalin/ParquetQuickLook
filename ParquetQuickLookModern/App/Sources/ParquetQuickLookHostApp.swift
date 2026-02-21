import SwiftUI

@main
struct ParquetQuickLookHostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Parquet Quick Look")
                    .font(.title2)
                    .bold()
                Text("This app installs a Finder Quick Look extension for .parquet files.")
                Text("Keep this app installed in /Applications and open Finder Quick Look with Space.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 520, minHeight: 180)
        }
    }
}

