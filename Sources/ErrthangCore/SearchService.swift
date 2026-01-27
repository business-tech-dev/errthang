import Foundation
import CoreData
import SwiftUI

public struct SearchResultItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String // path
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?

    // Cache lowercased name for faster search
    public let lowercasedName: String

    public init(id: String, name: String, path: String, isDirectory: Bool, size: Int64, modificationDate: Date?) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.lowercasedName = name.lowercased()
    }

    // Custom coding keys to exclude lowercasedName if we wanted, but including it trades disk space for load CPU.
    // Let's include it to make load faster (no re-computation).
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case isDirectory
        case size
        case modificationDate
        case lowercasedName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        size = try container.decode(Int64.self, forKey: .size)
        modificationDate = try container.decodeIfPresent(Date.self, forKey: .modificationDate)
        lowercasedName = try container.decode(String.self, forKey: .lowercasedName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try container.encode(lowercasedName, forKey: .lowercasedName)
    }

    public var dateForSorting: Date { modificationDate ?? .distantPast }
}

public struct SearchResults: RandomAccessCollection, Sendable {
    public typealias Index = Int
    public typealias Element = SearchResultItem

    private let binaryIndex: BinaryIndex?
    // Mixed storage:
    // If >= 0: Binary Index ID
    // If < 0: Delta Index ID (bitwise negated) -> ~value to get index into deltaItems
    private let virtualIndices: [Int64]
    private let deltaItems: [SearchResultItem]

    // Legacy support for materialized only
    private let materializedItems: [SearchResultItem]
    private let mode: Mode

    private enum Mode {
        case virtual
        case materialized
    }

    // Virtual Constructor
    public init(binaryIndex: BinaryIndex, virtualIndices: [Int64], deltaItems: [SearchResultItem]) {
        self.binaryIndex = binaryIndex
        self.virtualIndices = virtualIndices
        self.deltaItems = deltaItems
        self.materializedItems = []
        self.mode = .virtual
    }

    // Convenience for pure binary
    public init(binaryIndex: BinaryIndex, indices: [Int32]) {
        self.binaryIndex = binaryIndex
        self.virtualIndices = indices.map { Int64($0) }
        self.deltaItems = []
        self.materializedItems = []
        self.mode = .virtual
    }

    // Materialized Constructor
    public init(items: [SearchResultItem]) {
        self.binaryIndex = nil
        self.virtualIndices = []
        self.deltaItems = []
        self.materializedItems = items
        self.mode = .materialized
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int {
        switch mode {
        case .virtual: return virtualIndices.count
        case .materialized: return materializedItems.count
        }
    }

    public subscript(position: Int) -> SearchResultItem {
        switch mode {
        case .virtual:
            let vIdx = virtualIndices[position]
            if vIdx >= 0 {
                // Binary Index
                if let item = binaryIndex?.getItem(at: Int32(vIdx)) {
                    return item
                }
            } else {
                // Delta Item
                let deltaIdx = Int(~vIdx) // Bitwise NOT to restore index
                if deltaIdx >= 0 && deltaIdx < deltaItems.count {
                    return deltaItems[deltaIdx]
                }
            }
            // Fallback
            return SearchResultItem(id: "error", name: "Error", path: "", isDirectory: false, size: 0, modificationDate: nil)

        case .materialized:
            return materializedItems[position]
        }
    }
}

private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

public actor SearchService {
    public static let shared = SearchService()

    public static let indexUpdatedNotification = Notification.Name("ErrthangIndexUpdated")
    public static let indexLoadingStartedNotification = Notification.Name("ErrthangIndexLoadingStarted")
    public static let indexLoadingFinishedNotification = Notification.Name("ErrthangIndexLoadingFinished")

    private var binaryIndex: BinaryIndex?
    private var deltaItems: [String: SearchResultItem] = [:] // Items modified/added since load (Live Updates)
    private var fastPathItems: [SearchResultItem] = [] // Temporary items for immediate UI feedback
    private var deletedPaths: Set<String> = [] // Items removed since load
    private var isIndexLoaded = false
    private var isLoadingState = false

    private let cacheURL: URL
    private let binIndexURL: URL
    private var saveTask: Task<Void, Error>?

    // Cancellation Token for indexing operations
    private var indexingGeneration = UUID()

    public func cancelIndexing() {
        indexingGeneration = UUID()
    }

    public var currentGeneration: UUID {
        indexingGeneration
    }

    public func isValidGeneration(_ token: UUID) -> Bool {
        token == indexingGeneration
    }

    private init() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".config/errthang")

        // Ensure directory exists
        if !fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        self.cacheURL = configDir.appendingPathComponent("index.cache") // Legacy
        self.binIndexURL = configDir.appendingPathComponent("index.bin")
    }

    public var count: Int {
        if let bin = binaryIndex {
            return bin.itemCount + deltaItems.count - deletedPaths.count
        }
        return 0
    }

    public var isLoading: Bool { isLoadingState }

    public func loadIndex() async {
        isLoadingState = true
        await MainActor.run { NotificationCenter.default.post(name: SearchService.indexLoadingStartedNotification, object: nil) }

        // Try loading Binary Index (Fastest)
        if loadBinaryIndex() {
            print("Binary Index Loaded instantly.")
            isLoadingState = false
            await MainActor.run {
                NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil)
                NotificationCenter.default.post(name: SearchService.indexLoadingFinishedNotification, object: nil)
            }
            return
        }

        // If binary load failed, we must rebuild from DB
        print("Binary index missing or corrupt. Rebuilding from DB...")

        // Phase 1: Fast Path (DB 1000) so user sees something
        await loadFastPath()

        // Phase 2: Full Build
        await rebuildIndexFromDB()
    }

    private func loadBinaryIndex() -> Bool {
        if let index = BinaryIndex(fileURL: binIndexURL) {
            self.binaryIndex = index
            self.isIndexLoaded = true
            return true
        }
        return false
    }

    private func rebuildIndexFromDB() async {
        let context = await PersistenceController.shared.newBackgroundContext()
        let start = Date()

        // Fetch ALL items to write new binary index
        let success = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "FileItem")
            request.resultType = .dictionaryResultType
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            request.propertiesToFetch = ["path", "name", "isDirectory", "size", "modificationDate"]

            do {
                let results = try context.fetch(request)
                print("Fetched \(results.count) items from DB for indexing in \(Date().timeIntervalSince(start))s")

                let items = results.compactMap { self.createItem(from: $0) }

                // Write Binary Index
                try BinaryIndexWriter.write(items: items, to: self.binIndexURL)
                print("Wrote binary index to disk.")
                return true

            } catch {
                print("Failed to rebuild index: \(error)")
                return false
            }
        }

        if success {
            // Load it (Actor Context)
            if self.loadBinaryIndex() {
                self.fastPathItems.removeAll() // Clear fast path as it's now in the binary index
                // We DO NOT clear deltaItems/deletedPaths here.
                // Reason: Race condition.
                // If an update came in (FileMonitor) while we were rebuilding, it is in deltaItems.
                // The binary index we just wrote might NOT have it (snapshot was taken earlier).
                // By keeping deltaItems, we ensure the live update overrides the potentially stale binary entry.
                // The memory cost (duplicate fast path items) is negligible compared to correctness.
            }
        }

        isLoadingState = false
        await MainActor.run {
            NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil)
            NotificationCenter.default.post(name: SearchService.indexLoadingFinishedNotification, object: nil)
        }
    }

    private func loadFastPath() async {
        print("Phase 1: Loading fast cache...")
        let context = await PersistenceController.shared.newBackgroundContext()

        let fastItems: [SearchResultItem] = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "FileItem")
            request.resultType = .dictionaryResultType
            request.fetchLimit = 1000
            request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            request.propertiesToFetch = ["path", "name", "isDirectory", "size", "modificationDate"]

            do {
                let results = try context.fetch(request)
                return results.compactMap { self.createItem(from: $0) }
            } catch {
                print("Fast load failed: \(error)")
                return []
            }
        }

        if !fastItems.isEmpty {
            self.fastPathItems = fastItems
            Task { @MainActor in NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil) }
        }
    }

    // Legacy method, not used for binary index
    private func loadIndexFromDisk() async -> Bool { return false }
    public func saveIndex() {
        // Trigger a rebuild if needed, but debounce
        scheduleAutoSave()
    }

    // Helper to create item from dictionary (non-isolated to be Sendable-friendly if needed, but here it's fine as func)
    private nonisolated func createItem(from dict: NSDictionary) -> SearchResultItem? {
        guard let path = dict["path"] as? String,
              let name = dict["name"] as? String else { return nil }

        let isDirectory = dict["isDirectory"] as? Bool ?? false
        let size = dict["size"] as? Int64 ?? 0
        let modificationDate = dict["modificationDate"] as? Date

        return SearchResultItem(
            id: path,
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: size,
            modificationDate: modificationDate
        )
    }

    private func updateFastCache(_ items: [SearchResultItem]) {} // No-op now

    public func search(query: String, sortOrder: [KeyPathComparator<SearchResultItem>] = [], limit: Int = 0) -> (results: SearchResults, totalCount: Int) {
        guard let index = binaryIndex else {
            // Fallback to fastPath + deltaItems if index not loaded yet
            var combined = [String: SearchResultItem]()
            for item in fastPathItems { combined[item.path] = item }
            for item in deltaItems.values { combined[item.path] = item }

            let matches = combined.values.filter {
                if query.isEmpty { return true }
                return $0.name.localizedCaseInsensitiveContains(query)
            }.sorted { $0.name < $1.name }
            return (SearchResults(items: matches), matches.count)
        }

        // 1. Get Binary Indices
        var binIndices = index.searchIndices(query: query)

        // 2. Filter Deleted Items (Efficiently)
        if !deletedPaths.isEmpty {
            // Optimization: Cache this if deletedPaths changes rarely but searched often?
            // For now, compute on fly. It's fast with C-scan.
            let deletedIndices = index.getIndices(forPaths: Array(deletedPaths))
            if !deletedIndices.isEmpty {
                binIndices.removeAll { deletedIndices.contains($0) }
            }
        }

        // 3. Sort Binary Indices (C-based In-Place)
        var sortKey: BinaryIndex.SortKey = .name
        var ascending = true

        if let comparator = sortOrder.first {
            ascending = comparator.order == .forward
            switch comparator.keyPath {
            case \SearchResultItem.name: sortKey = .name
            case \SearchResultItem.path: sortKey = .path
            case \SearchResultItem.size: sortKey = .size
            case \SearchResultItem.dateForSorting: sortKey = .date
            case \SearchResultItem.modificationDate: sortKey = .date
            default: break
            }
        }

        index.sort(indices: &binIndices, by: sortKey, ascending: ascending)

        // 4. Get Delta Matches
        let queryTokens = query.lowercased().split(separator: " ")
        var matchingDeltas = deltaItems.values.filter { delta in
            if query.isEmpty { return true }
            for token in queryTokens {
                if !delta.lowercasedName.contains(token) { return false }
            }
            return true
        }

        // Sort Deltas (Swift)
        if !sortOrder.isEmpty {
             matchingDeltas.sort(using: sortOrder)
        } else {
             matchingDeltas.sort { $0.name < $1.name }
        }

        // 5. Merge (Virtual Merge)
        // We have two sorted lists: binIndices (Int32) and matchingDeltas (SearchResultItem)
        // We produce [Int64]

        var virtualIndices: [Int64] = []
        virtualIndices.reserveCapacity(binIndices.count + matchingDeltas.count)

        var binPtr = 0
        var deltaPtr = 0

        // Helper to get comparison value from Binary Index without full materialization (if possible)
        // Actually, for perfect merge, we DO need to compare values.
        // CSearch doesn't easily expose "compare index X with value Y".
        // However, deltas are usually SMALL.
        // If deltas are small, we can just insert them?
        // Or, we can accept that merging requires materializing binary items just for the comparison.
        // BUT: materializing just for comparison is cheaper than materializing ALL for array storage.
        // OPTIMIZATION: If deltas are empty, just use binary.

        if matchingDeltas.isEmpty {
             let finalIndices = limit > 0 ? Array(binIndices.prefix(limit)) : binIndices
             return (SearchResults(binaryIndex: index, indices: finalIndices), binIndices.count)
        }

        // Full Merge Logic
        while binPtr < binIndices.count && deltaPtr < matchingDeltas.count {
            let binIdx = binIndices[binPtr]
            let deltaItem = matchingDeltas[deltaPtr]

            // We need to compare binIdx vs deltaItem

            var binIsSmaller = false
            let comparison = index.compare(index: binIdx, with: deltaItem, by: sortKey)

            if comparison == .orderedAscending {
                binIsSmaller = true
            } else if comparison == .orderedDescending {
                binIsSmaller = false
            } else {
                // Equal. Prefer binary? or Delta?
                // Usually doesn't matter for sort stability if unique.
                // Let's say false so delta comes second (or first? stable sort usually keeps original order)
                // If ids are same, we should have filtered binary out via deletedPaths or other logic.
                binIsSmaller = true
            }

            if !ascending {
                // Invert logic for descending sort
                // If we want descending, and bin is "smaller" (lexicographically), then bin should come AFTER delta.
                // So binIsSmaller (meaning bin < delta) implies bin should be processed LATER.
                // wait.
                // Ascending: [A, B]. A < B. Take A.
                // Descending: [B, A]. A < B. Take B.

                // If bin < delta (orderedAscending):
                //   Ascending: Pick Bin.
                //   Descending: Pick Delta.

                // If bin > delta (orderedDescending):
                //   Ascending: Pick Delta.
                //   Descending: Pick Bin.

                if comparison == .orderedAscending {
                    binIsSmaller = false // Pick delta
                } else if comparison == .orderedDescending {
                    binIsSmaller = true // Pick bin
                }
            }

            if binIsSmaller {
                virtualIndices.append(Int64(binIdx))
                binPtr += 1
            } else {
                // Delta is smaller (or equal)
                // Encode delta index: ~ptr
                virtualIndices.append(~Int64(deltaPtr))
                deltaPtr += 1
            }
        }

        // Flush remaining
        while binPtr < binIndices.count {
            virtualIndices.append(Int64(binIndices[binPtr]))
            binPtr += 1
        }
        while deltaPtr < matchingDeltas.count {
            virtualIndices.append(~Int64(deltaPtr))
            deltaPtr += 1
        }

        let totalCount = virtualIndices.count
        let finalIndices = limit > 0 ? Array(virtualIndices.prefix(limit)) : virtualIndices

        return (SearchResults(binaryIndex: index, virtualIndices: finalIndices, deltaItems: matchingDeltas), totalCount)
    }

    public func reload() async {
        await loadIndex()
    }

    public func update(item: SearchResultItem) {
        deltaItems[item.path] = item
        deletedPaths.remove(item.path)
        scheduleAutoSave()
        Task { @MainActor in NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil) }
    }

    public func addBatch(_ newItems: [SearchResultItem]) {
        for item in newItems {
            deltaItems[item.path] = item
            deletedPaths.remove(item.path)
        }
        scheduleAutoSave()
        Task { @MainActor in NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil) }
    }

    public func remove(path: String) {
        deletedPaths.insert(path)
        deltaItems.removeValue(forKey: path)
        scheduleAutoSave()
        Task { @MainActor in NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil) }
    }

    public func remove(prefix: String) {
        // This is hard with binary index + set.
        // We'd need to find all paths starting with prefix in binary index.
        // For now, let's just trigger a full rebuild if this happens (rare, usually bulk delete)
        // Or strictly rely on FileMonitor updates
        Task { await rebuildIndexFromDB() }
    }

    public func clear() {
        binaryIndex = nil
        deltaItems.removeAll()
        deletedPaths.removeAll()
        try? FileManager.default.removeItem(at: binIndexURL)
        Task { @MainActor in NotificationCenter.default.post(name: SearchService.indexUpdatedNotification, object: nil) }
    }

    public func forceRebuild() async {
        saveTask?.cancel()
        await rebuildIndexFromDB()
    }

    private func scheduleAutoSave() {
        // For binary index, "Auto Save" means rebuilding the binary file from DB
        // We only do this if deltas get too large or on a long timer
        saveTask?.cancel()
        saveTask = Task {
            // Debounce for 5 seconds
            try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            await rebuildIndexFromDB()
        }
    }
}
