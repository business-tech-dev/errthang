import Foundation
import CSearch

public struct BinaryIndexItem {
    public let nameOffset: UInt32
    public let nameLength: UInt32
    public let pathOffset: UInt32
    public let pathLength: UInt32
    public let lowerNameOffset: UInt32
    public let lowerNameLength: UInt32
    public let size: Int64
    public let modDate: TimeInterval
    public let isDirectory: Bool
}

// Memory layout for the item record (fixed size)
// We use a manual byte packing for maximum performance and stability
private let ITEM_RECORD_SIZE = 48

private struct BufferWrapper<Element>: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Element>
}

public final class BinaryIndex: @unchecked Sendable {
    private let data: Data
    private let count: Int
    private let itemBaseOffset: Int

    public init?(fileURL: URL) {
        do {
            // Map the file into memory (Zero-Copy)
            // .mappedIfSafe allows the OS to manage paging
            self.data = try Data(contentsOf: fileURL, options: [.mappedIfSafe, .alwaysMapped])

            // Basic validation
            let headerSize = 16
            guard data.count >= headerSize else { return nil }

            // Check Magic "ERRT" (0x45 0x52 0x52 0x54)
            let magicValid = data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return false }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                return bytes[0] == 0x45 && // E
                       bytes[1] == 0x52 && // R
                       bytes[2] == 0x52 && // R
                       bytes[3] == 0x54    // T
            }
            guard magicValid else { return nil }

            // Check Version
            let version = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 4, as: Int32.self)
            }
            guard version == 2 else {
                print("Binary index version mismatch (found \(version), expected 2). Rebuilding.")
                return nil
            }

            // Read Count
            self.count = Int(data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: 8, as: Int64.self)
            })

            self.itemBaseOffset = headerSize

            // Basic bounds check
            if data.count < itemBaseOffset + (count * ITEM_RECORD_SIZE) {
                return nil
            }

        } catch {
            print("Failed to load binary index: \(error)")
            return nil
        }
    }

    public var itemCount: Int {
        return count
    }

    public func searchIndices(query: String) -> [Int32] {
        let queryTokens = query.lowercased().utf8
        let queryBytes = Array(queryTokens)

        // If empty query, return all indices
        if query.isEmpty {
            var results = [Int32]()
            results.reserveCapacity(count)
            for i in 0..<count {
                results.append(Int32(i))
            }
            return results
        }

        // Parallel Scan
        let workerCount = ProcessInfo.processInfo.activeProcessorCount
        let batchSize = (count + workerCount - 1) / workerCount // Ceiling division

        var threadResults = Array(repeating: [Int32](), count: workerCount)

        // Use UnsafeMutableBufferPointer to update threadResults safely
        threadResults.withUnsafeMutableBufferPointer { resultsBuffer in
            let wrapper = BufferWrapper(buffer: resultsBuffer)

            // Capture these to avoid self capture in closure if possible, or just access properties
            let count = self.count
            let itemBaseOffset = self.itemBaseOffset
            let recordSize = ITEM_RECORD_SIZE

            DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
                let start = workerIndex * batchSize
                if start >= count { return }
                let end = min(start + batchSize, count)
                let actualBatchSize = end - start

                // Pre-allocate buffer for worst-case matches
                let bufferPtr = UnsafeMutablePointer<Int32>.allocate(capacity: actualBatchSize)
                defer { bufferPtr.deallocate() }

                var matchCount: Int32 = 0

                self.data.withUnsafeBytes { dataBuffer in
                    guard let base = dataBuffer.baseAddress else { return }

                    // Call C function
                    // Note: We pass the base pointer of the file, offsets, and query info
                    queryBytes.withUnsafeBufferPointer { queryBuffer in
                        guard let queryBase = queryBuffer.baseAddress else { return }

                        matchCount = perform_search_scan(
                            base.assumingMemoryBound(to: UInt8.self),
                            Int(itemBaseOffset),
                            Int(recordSize),
                            Int(start),
                            Int(end),
                            queryBase,
                            Int(queryBuffer.count),
                            bufferPtr
                        )
                    }
                }

                // Copy results to Swift array
                if matchCount > 0 {
                    let buffer = UnsafeBufferPointer(start: bufferPtr, count: Int(matchCount))
                    wrapper.buffer[workerIndex] = Array(buffer)
                }
            }
        }

        return threadResults.flatMap { $0 }
    }

    public func getItem(at index: Int32) -> SearchResultItem? {
        return getItem(at: Int(index))
    }

    public func find(path: String) -> Int32? {
        let pathBytes = Array(path.utf8)

        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }

            return pathBytes.withUnsafeBufferPointer { pathBuffer in
                guard let pathBase = pathBuffer.baseAddress else { return nil }

                let result = perform_path_lookup(
                    base.assumingMemoryBound(to: UInt8.self),
                    Int(itemBaseOffset),
                    Int(ITEM_RECORD_SIZE),
                    Int(count),
                    pathBase,
                    Int(pathBytes.count)
                )

                return result >= 0 ? result : nil
            }
        }
    }

    public func getPath(at index: Int32) -> String? {
        guard index >= 0 && index < count else { return nil }

        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            let itemPtr = base.advanced(by: itemBaseOffset + (Int(index) * ITEM_RECORD_SIZE))

            // Read path location (28, 32)
            let pathOffset = itemPtr.load(fromByteOffset: 28, as: UInt32.self)
            let pathLen = itemPtr.load(fromByteOffset: 32, as: UInt32.self)

            let pathBytes = UnsafeBufferPointer(start: base.advanced(by: Int(pathOffset)).assumingMemoryBound(to: UInt8.self), count: Int(pathLen))
            return String(decoding: pathBytes, as: UTF8.self)
        }
    }

    public func getIndices(forPaths paths: [String]) -> Set<Int32> {
        var result = Set<Int32>()

        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            for path in paths {
                let pathBytes = Array(path.utf8)
                pathBytes.withUnsafeBufferPointer { pathBuf in
                    guard let pathBase = pathBuf.baseAddress else { return }
                    let idx = perform_path_lookup(
                        ptr,
                        Int(itemBaseOffset),
                        Int(ITEM_RECORD_SIZE),
                        Int(count),
                        pathBase,
                        Int(pathBuf.count)
                    )
                    if idx >= 0 {
                        result.insert(idx)
                    }
                }
            }
        }
        return result
    }

    public enum SortKey {
        case name
        case path
        case size
        case date
    }

    public func sort(indices: inout [Int32], by key: SortKey, ascending: Bool) {
        guard !indices.isEmpty else { return }

        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }

            // Map SortKey to C enum
            let searchKey: SearchSortKey
            switch key {
            case .name: searchKey = SORT_KEY_NAME
            case .path: searchKey = SORT_KEY_PATH
            case .size: searchKey = SORT_KEY_SIZE
            case .date: searchKey = SORT_KEY_DATE
            }

            indices.withUnsafeMutableBufferPointer { idxBuffer in
                guard let idxPtr = idxBuffer.baseAddress else { return }

                perform_index_sort(
                    idxPtr,
                    idxBuffer.count,
                    base.assumingMemoryBound(to: UInt8.self),
                    Int(itemBaseOffset),
                    Int(ITEM_RECORD_SIZE),
                    searchKey,
                    ascending
                )
            }
        }
    }

    public func compare(index: Int32, with item: SearchResultItem, by key: SortKey) -> ComparisonResult {
        guard index >= 0 && index < count else { return .orderedSame }

        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return .orderedSame }
            let itemPtr = base.advanced(by: itemBaseOffset + (Int(index) * ITEM_RECORD_SIZE))

            switch key {
            case .name:
                let nameOffset = itemPtr.load(fromByteOffset: 20, as: UInt32.self)
                let nameLen = itemPtr.load(fromByteOffset: 24, as: UInt32.self)
                return compareBytes(base: base, offset: nameOffset, len: nameLen, with: item.name)
            case .path:
                let pathOffset = itemPtr.load(fromByteOffset: 28, as: UInt32.self)
                let pathLen = itemPtr.load(fromByteOffset: 32, as: UInt32.self)
                return compareBytes(base: base, offset: pathOffset, len: pathLen, with: item.path)
            case .size:
                let size = itemPtr.load(fromByteOffset: 0, as: Int64.self)
                if size < item.size { return .orderedAscending }
                if size > item.size { return .orderedDescending }
                return .orderedSame
            case .date:
                let modInterval = itemPtr.load(fromByteOffset: 8, as: TimeInterval.self)
                let otherDate = item.dateForSorting.timeIntervalSince1970
                if modInterval < otherDate { return .orderedAscending }
                if modInterval > otherDate { return .orderedDescending }
                return .orderedSame
            }
        }
    }

    private func compareBytes(base: UnsafeRawPointer, offset: UInt32, len: UInt32, with string: String) -> ComparisonResult {
        let ptr = base.advanced(by: Int(offset)).assumingMemoryBound(to: UInt8.self)

        // Byte-wise comparison (memcmp style) to match CSearch sorting
        var i = 0
        for b2 in string.utf8 {
            if i >= Int(len) {
                // Binary string ran out first -> Binary is smaller
                return .orderedAscending
            }
            let b1 = ptr[i]
            if b1 < b2 { return .orderedAscending }
            if b1 > b2 { return .orderedDescending }
            i += 1
        }

        // String ran out.
        if i < Int(len) {
            // Binary string still has bytes -> Binary is larger
            return .orderedDescending
        }

        return .orderedSame
    }

    private func getItem(at index: Int) -> SearchResultItem? {
        guard index >= 0 && index < count else { return nil }

        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            let itemPtr = base.advanced(by: itemBaseOffset + (index * ITEM_RECORD_SIZE))
            return materializeItem(from: itemPtr, base: base)
        }
    }

    private func materializeItem(from itemPtr: UnsafeRawPointer, base: UnsafeRawPointer) -> SearchResultItem? {
        // Read fields
        // Layout Version 2 (Aligned):
        // 0: size (Int64) - Aligned 8
        // 8: modDate (Double) - Aligned 8
        // 16: flags (UInt8)
        // 17-19: reserved
        // 20: nameOffset (UInt32)
        // 24: nameLen (UInt32)
        // 28: pathOffset (UInt32)
        // 32: pathLen (UInt32)
        // 36: lowerNameOffset (UInt32)
        // 40: lowerNameLen (UInt32)

        let size = itemPtr.load(fromByteOffset: 0, as: Int64.self)
        let modInterval = itemPtr.load(fromByteOffset: 8, as: TimeInterval.self)

        let flags = itemPtr.load(fromByteOffset: 16, as: UInt8.self)
        let isDirectory = (flags & 1) != 0

        let nameOffset = itemPtr.load(fromByteOffset: 20, as: UInt32.self)
        let nameLen = itemPtr.load(fromByteOffset: 24, as: UInt32.self)

        let pathOffset = itemPtr.load(fromByteOffset: 28, as: UInt32.self)
        let pathLen = itemPtr.load(fromByteOffset: 32, as: UInt32.self)

        // Reconstruct Strings safely (copying bytes to avoid UAF if Data is released)
        let nameBytes = UnsafeBufferPointer(start: base.advanced(by: Int(nameOffset)).assumingMemoryBound(to: UInt8.self), count: Int(nameLen))
        let name = String(decoding: nameBytes, as: UTF8.self)

        let pathBytes = UnsafeBufferPointer(start: base.advanced(by: Int(pathOffset)).assumingMemoryBound(to: UInt8.self), count: Int(pathLen))
        let path = String(decoding: pathBytes, as: UTF8.self)

        return SearchResultItem(
            id: path,
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: size,
            modificationDate: Date(timeIntervalSince1970: modInterval)
        )
    }
}

public class BinaryIndexWriter {
    public static func write(items: [SearchResultItem], to url: URL) throws {
        // Prepare Data buffers
        var headerData = Data()
        var itemData = Data()
        var stringPool = Data()

        let count = items.count

        // Header
        headerData.append(contentsOf: "ERRT".utf8)
        var version: Int32 = 2 // Version 2 for Aligned Layout
        withUnsafeBytes(of: &version) { headerData.append(contentsOf: $0) }
        var count64 = Int64(count)
        withUnsafeBytes(of: &count64) { headerData.append(contentsOf: $0) }

        // Pad header to 16 bytes if needed (already 4+4+8=16)

        // Pre-calculate offsets
        // Header: 16
        // Items: count * 48
        // Strings: start after that
        let stringPoolBaseOffset = 16 + (count * 48)
        var currentStringOffset = stringPoolBaseOffset

        // Sort items by name for default sort order in empty queries (Binary sort for speed)
        let sortedItems = items.sorted { $0.name < $1.name }

        for item in sortedItems {
            // Write Strings
            guard let nameBytes = item.name.data(using: .utf8),
                  let pathBytes = item.path.data(using: .utf8),
                  let lowerBytes = item.lowercasedName.data(using: .utf8) else { continue }

            let nameOffset = currentStringOffset
            stringPool.append(nameBytes)
            currentStringOffset += nameBytes.count

            let pathOffset = currentStringOffset
            stringPool.append(pathBytes)
            currentStringOffset += pathBytes.count

            let lowerOffset = currentStringOffset
            stringPool.append(lowerBytes)
            currentStringOffset += lowerBytes.count

            // Write Item Record (Layout V2)

            // 0: size (Aligned 8)
            var size = item.size
            withUnsafeBytes(of: &size) { itemData.append(contentsOf: $0) }

            // 8: modDate (Aligned 8)
            var mod = item.modificationDate?.timeIntervalSince1970 ?? 0
            withUnsafeBytes(of: &mod) { itemData.append(contentsOf: $0) }

            // 16: flags
            let flags: UInt8 = item.isDirectory ? 1 : 0
            itemData.append(flags)

            // 17-19: reserved (3 bytes)
            itemData.append(contentsOf: [0, 0, 0] as [UInt8])

            // 20: nameOffset
            var no = UInt32(nameOffset)
            withUnsafeBytes(of: &no) { itemData.append(contentsOf: $0) }

            // 24: nameLen
            var nl = UInt32(nameBytes.count)
            withUnsafeBytes(of: &nl) { itemData.append(contentsOf: $0) }

            // 28: pathOffset
            var po = UInt32(pathOffset)
            withUnsafeBytes(of: &po) { itemData.append(contentsOf: $0) }

            // 32: pathLen
            var pl = UInt32(pathBytes.count)
            withUnsafeBytes(of: &pl) { itemData.append(contentsOf: $0) }

            // 36: lowerNameOffset
            var lo = UInt32(lowerOffset)
            withUnsafeBytes(of: &lo) { itemData.append(contentsOf: $0) }

            // 40: lowerNameLen
            var ll = UInt32(lowerBytes.count)
            withUnsafeBytes(of: &ll) { itemData.append(contentsOf: $0) }

            // Total 44 bytes written. We need 48.
            // Pad 4 bytes
            itemData.append(contentsOf: [0, 0, 0, 0] as [UInt8])
        }

        // Combine
        var finalData = Data()
        finalData.append(headerData)
        finalData.append(itemData)
        finalData.append(stringPool)

        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Atomic Write
        // This writes to a temp file managed by the system and then renames it to the destination
        try finalData.write(to: url, options: .atomic)
    }
}
