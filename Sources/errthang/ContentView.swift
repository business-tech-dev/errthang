import SwiftUI
import CoreData
import ErrthangCore
import AppKit

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var configManager = ConfigManager.shared
    @State private var searchText = ""
    @State private var isIndexing = false
    @State private var isIndexLoading = false
    @FocusState private var isSearchFocused: Bool
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    // Decoupled search results
    @State private var searchResults: SearchResults = SearchResults(items: [])
    @State private var searchResultsVersion = UUID()
    @State private var selection: Set<SearchResultItem.ID> = []
    @State private var totalItemCount: Int = 0
    @State private var sortDescriptors: [NSSortDescriptor] = [
        NSSortDescriptor(key: "name", ascending: true)
    ]
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: App Title & Item Count
            HStack {
                if let logoURL = Bundle.main.url(forResource: "AppLogo", withExtension: "jpg"),
                   let nsImage = NSImage(contentsOf: logoURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                }

                Text("errthang")
                    .font(.headline)
                    .fontWeight(.bold)

                Spacer()

                if isIndexLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                }

                Text(searchText.isEmpty ? "\(totalItemCount) files" : "\(searchResults.count) Results")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 4)

            // Row 2: Search Bar & Settings
            HStack {
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onSubmit {
                        configManager.addSearchHistory(searchText)
                    }

                SettingsLink {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding([.horizontal, .bottom])

            resultsTable
        }
        .navigationTitle(" ")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 800, minHeight: 500)
        .background(WindowAccessor(window: $window))
        .onAppear {
            print("Errthang UI Ready")

            // Check initial loading state
            Task {
                let loading = await SearchService.shared.isLoading
                await MainActor.run { self.isIndexLoading = loading }
            }

            // Restore Sort Order
            let sortConfig = configManager.config.sortConfig
            sortDescriptors = [NSSortDescriptor(key: sortConfig.key, ascending: sortConfig.isAscending)]

            // Restore saved paths
            restoreSavedPaths()

            // Initial load
            Task {
                let results = await performSearch(query: "", sortDescriptors: sortDescriptors)
                await MainActor.run {
                    self.searchResults = results
                    self.searchResultsVersion = UUID()
                }
            }
        }
        .onChange(of: sortDescriptors) { _, newDescriptors in
            // Update sort config for persistence
            guard let first = newDescriptors.first, let key = first.key else { return }

            // Map "dateForSorting" back to "date" for config if needed, or just use the key from FastTableView
            // FastTableView keys: name, path, size, type, dateForSorting
            // ConfigManager keys expected: name, path, size, type, date

            var configKey = key
            if key == "dateForSorting" { configKey = "date" }

            let newConfig = SortConfig(key: configKey, isAscending: first.ascending)
            if configManager.config.sortConfig != newConfig {
                configManager.config.sortConfig = newConfig
                configManager.save()
            }

            // Re-fetch with new sort order
            Task {
                let results = await performSearch(query: searchText, sortDescriptors: newDescriptors)
                DispatchQueue.main.async {
                    self.searchResults = results
                    self.searchResultsVersion = UUID()
                }
            }
        }
        .onChange(of: window) { _, newWindow in
            updateWindowAutosave(newWindow)
        }
        .onChange(of: configManager.config.rememberWindowPosition) { _, _ in
            updateWindowAutosave(window)
        }
        .task(id: searchText) {
            print("Task triggered for query: '\(searchText)'")
            do {
                // Debounce to allow typing to flow; 100ms is snappy but prevents thrashing
                try await Task.sleep(nanoseconds: 100_000_000)

                if Task.isCancelled { return }

                print("Performing search for: '\(searchText)'")
                // Perform search on background context and await results
                let results = await performSearch(query: searchText, sortDescriptors: sortDescriptors)
                print("Search returned \(results.count) results for: '\(searchText)'")

                // Only update UI if this task is still valid (not cancelled by new typing)
                if !Task.isCancelled {
                    self.searchResults = results
                    self.searchResultsVersion = UUID()
                }
            } catch {
                // Task cancelled
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchService.indexLoadingStartedNotification)) { _ in
            DispatchQueue.main.async { self.isIndexLoading = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchService.indexLoadingFinishedNotification)) { _ in
            DispatchQueue.main.async { self.isIndexLoading = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchService.indexUpdatedNotification)) { _ in
            // Refresh current search results
            Task {
                let results = await performSearch(query: searchText, sortDescriptors: sortDescriptors)
                await MainActor.run {
                    self.searchResults = results
                    self.searchResultsVersion = UUID()
                }
            }
        }
    }

    private func updateWindowAutosave(_ window: NSWindow?) {
        guard let window = window else { return }
        // Always remember window position
        window.setFrameAutosaveName("ErrthangMainWindow")
        window.titleVisibility = .hidden
        window.title = ""
        window.subtitle = ""
    }

    private var resultsTable: some View {
        FastTableView(
            items: searchResults,
            itemsVersion: searchResultsVersion,
            selection: $selection,
            sortDescriptors: $sortDescriptors,
            onRevealInFinder: { paths in revealInFinder(paths: paths) },
            onCopyPath: { paths in copyPaths(paths: paths) },
            onCopyName: { paths in copyNames(paths: paths) }
        )
    }

    private func revealInFinder(paths: Set<String>) {
        for path in paths {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }

    private func copyPaths(paths: Set<String>) {
        let text = paths.sorted().joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyNames(paths: Set<String>) {
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted().joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(names, forType: .string)
    }

    @ViewBuilder
    private func nameCell(_ item: SearchResultItem) -> some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder" : "doc")
            Text(item.name)
        }
    }

    @ViewBuilder
    private func pathCell(_ item: SearchResultItem) -> some View {
        Text(item.path)
            .truncationMode(.middle)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func sizeCell(_ item: SearchResultItem) -> some View {
        Text(Formatters.byteCountFormatter.string(fromByteCount: item.size))
            .monospacedDigit()
    }

    @ViewBuilder
    private func dateCell(_ item: SearchResultItem) -> some View {
        Text(item.modificationDate?.formatted(date: .numeric, time: .shortened) ?? "-")
            .monospacedDigit()
    }

    private func performSearch(query: String, sortDescriptors: [NSSortDescriptor] = []) async -> SearchResults {
        // Convert NSSortDescriptor to KeyPathComparator
        var comparators: [KeyPathComparator<SearchResultItem>] = []
        if let first = sortDescriptors.first, let key = first.key {
            let order: SortOrder = first.ascending ? .forward : .reverse
            switch key {
            case "name": comparators.append(.init(\.name, order: order))
            case "path": comparators.append(.init(\.path, order: order))
            case "size": comparators.append(.init(\.size, order: order))
            case "dateForSorting": comparators.append(.init(\.dateForSorting, order: order))
            default: break
            }
        }

        let (results, count) = await SearchService.shared.search(query: query, sortOrder: comparators, limit: 0)

        if query.isEmpty {
            await MainActor.run {
                self.totalItemCount = count
            }
        }

        return results
    }

    private func restoreSavedPaths() {
        let shares = ConfigManager.shared.config.smbShares
        for share in shares {
            guard let url = URL(string: share.url) else { continue }

            if url.isFileURL {
                print("Restored saved path: \(url.path)")
            } else {
                Task {
                    do {
                        let mountPath = try await SMBManager.shared.connect(to: url)
                        print("Restored connection to \(mountPath)")
                    } catch {
                        print("Failed to restore share \(share.url): \(error)")
                    }
                }
            }
        }
    }
}

struct Formatters {
    @MainActor static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
