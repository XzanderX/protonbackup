import SwiftUI

/// Built-in log viewer with filtering, search, and copy-to-clipboard.
struct LogViewerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var logService = LogService.shared

    @State private var searchText = ""
    @State private var selectedLevel: LogLevel? = nil
    @State private var selectedCategory: LogCategory? = nil
    @State private var autoScroll = true

    private var filteredEntries: [BackupLogEntry] {
        logService.filteredEntries(
            minLevel: selectedLevel,
            category: selectedCategory,
            searchText: searchText.isEmpty ? nil : searchText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                // Level filter
                Picker("Level", selection: $selectedLevel) {
                    Text("All Levels").tag(nil as LogLevel?)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level as LogLevel?)
                    }
                }
                .frame(width: 120)

                // Category filter
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(nil as LogCategory?)
                    ForEach(LogCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue).tag(cat as LogCategory?)
                    }
                }
                .frame(width: 130)

                Spacer()

                // Actions
                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Auto-scroll to bottom")

                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy log to clipboard")

                Button {
                    logService.clearEntries()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear log entries")
            }
            .padding(10)

            Divider()

            // Log entries
            if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No log entries")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    List(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .listStyle(.plain)
                    .onChange(of: filteredEntries.count) { _ in
                        if autoScroll, let last = filteredEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Status bar
            HStack {
                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if let lastEntry = filteredEntries.last {
                    Text("Latest: \(lastEntry.formattedTimestamp)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func copyToClipboard() {
        let text = filteredEntries.map(\.displayLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: BackupLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: levelIcon)
                .foregroundColor(levelColor)
                .frame(width: 12)

            Text(entry.formattedTimestamp)
                .foregroundColor(.secondary)

            Text("[\(entry.category.rawValue)]")
                .foregroundColor(.protonPurple.opacity(0.8))

            Text(entry.message)
                .foregroundColor(.primary)

            if let filePath = entry.filePath {
                Text(filePath)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.vertical, 1)
    }

    private var levelIcon: String {
        switch entry.level {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .statusYellow
        case .error: return .statusRed
        }
    }
}
