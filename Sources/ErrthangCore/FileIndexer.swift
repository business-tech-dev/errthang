import Foundation
import CoreData

public actor FileIndexer {
    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    public func index(path: String) async {
        // Capture cancellation token
        let token = await SearchService.shared.currentGeneration

        let startTime = Date()
        print("Starting index of \(path) at \(startTime)")

        // Check cancellation
        if await !SearchService.shared.isValidGeneration(token) {
            print("Indexing cancelled for \(path)")
            return
        }

        // Clear existing items for this path before re-indexing
        await clearIndex(path: path)

        let excludedPaths = await MainActor.run {
            ConfigManager.shared.config.excludedPaths
        }

        // Strictly use the provided path. Do not resolve symlinks.
        let rootURL = URL(fileURLWithPath: path)

        let fileManager = FileManager.default

        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            print("Failed to create enumerator for \(path)")
            return
        }

        var batch: [(path: String, name: String, isDirectory: Bool, size: Int64, modificationDate: Date?)] = []
        var counter = 0
        var loopCounter = 0
        let context = self.context

        while let fileURL = enumerator.nextObject() as? URL {
            loopCounter += 1

            // Periodically check cancellation even if not adding to batch (e.g. skipping many files)
            if loopCounter % 1000 == 0 {
                if await !SearchService.shared.isValidGeneration(token) || Task.isCancelled {
                    print("Indexing cancelled during enumeration for \(path)")
                    return
                }
            }

            let filePath = fileURL.path

            if excludedPaths.contains(where: { filePath.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }

            // Use path as-is
            let itemPath = filePath

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))

                // Skip files modified after indexing started (avoids churn loops)
                if let modDate = resourceValues.contentModificationDate, modDate > startTime {
                    continue
                }

                let item = (
                    path: itemPath,
                    name: fileURL.lastPathComponent,
                    isDirectory: resourceValues.isDirectory ?? false,
                    size: Int64(resourceValues.fileSize ?? 0),
                    modificationDate: resourceValues.contentModificationDate
                )
                batch.append(item)
                counter += 1
            } catch {
                // Ignore errors
            }

            if batch.count >= 1000 {
                // Check cancellation
                if await !SearchService.shared.isValidGeneration(token) || Task.isCancelled {
                    print("Indexing cancelled during batch processing for \(path)")
                    return
                }

                // We need to capture the current batch to pass it safely
                let currentBatch = batch

                // Perform DB save
                await performSaveBatch(currentBatch, context: context)

                batch.removeAll()
                print("Indexed \(counter) files...")
            }
        }

        if !batch.isEmpty {
            // Check cancellation
            if await !SearchService.shared.isValidGeneration(token) || Task.isCancelled {
                return
            }
            await performSaveBatch(batch, context: context)
        }

        // Check cancellation before rebuild
        if await !SearchService.shared.isValidGeneration(token) || Task.isCancelled {
            print("Indexing cancelled before rebuild for \(path)")
            return
        }

        // Trigger full binary index rebuild immediately
        await SearchService.shared.forceRebuild()

        let endTime = Date()
        print("Finished indexing \(counter) files at \(endTime). Duration: \(endTime.timeIntervalSince(startTime))s")
    }

    private func performSaveBatch(_ batch: [(path: String, name: String, isDirectory: Bool, size: Int64, modificationDate: Date?)], context: NSManagedObjectContext) async {
        await context.perform {
            // Map to dictionaries for NSBatchInsertRequest
            let objects = batch.map { item -> [String: Any] in
                return [
                    "path": item.path,
                    "name": item.name,
                    "isDirectory": item.isDirectory,
                    "size": item.size,
                    "modificationDate": item.modificationDate ?? NSNull()
                ]
            }

            // Use NSBatchInsertRequest for high-performance bulk insert
            let batchInsert = NSBatchInsertRequest(entityName: "FileItem", objects: objects)
            batchInsert.resultType = .statusOnly

            do {
                try context.execute(batchInsert)
            } catch {
                print("Error executing batch insert: \(error)")
            }

            context.reset()
        }
    }

    public func updateItem(at path: String) async {
        // Strictly use the provided path. Do not resolve symlinks.
        let resolvedPath = path
        let url = URL(fileURLWithPath: resolvedPath)
        let fileManager = FileManager.default
        let context = self.context

        // Use attributesOfItem to check existence and type without following symlinks
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath) else {
            await deleteItem(at: resolvedPath)
            return
        }

        let type = attributes[.type] as? FileAttributeType
        let isDirectoryValue = (type == .typeDirectory)
        let size = (attributes[.size] as? Int64) ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let name = url.lastPathComponent

        print("Updating file: \(resolvedPath), Size: \(size)")

        await context.perform {
            let request: NSFetchRequest<FileItem> = FileItem.fetchRequest()
            request.predicate = NSPredicate(format: "path == %@", resolvedPath)
            request.fetchLimit = 1

            do {
                let results = try context.fetch(request)
                let item = results.first ?? FileItem(context: context)

                item.path = resolvedPath
                item.name = name
                item.isDirectory = isDirectoryValue
                item.size = size
                item.modificationDate = modificationDate

                try context.save()
            } catch {
                print("Error updating file at \(resolvedPath): \(error)")
            }
        }

        let searchItem = SearchResultItem(
            id: resolvedPath,
            name: name,
            path: resolvedPath,
            isDirectory: isDirectoryValue,
            size: size,
            modificationDate: modificationDate
        )
        await SearchService.shared.update(item: searchItem)
    }

    private func deleteItem(at path: String) async {
        let context = self.context
        await context.perform {
            let request: NSFetchRequest<FileItem> = FileItem.fetchRequest()
            request.predicate = NSPredicate(format: "path == %@", path)

            do {
                let results = try context.fetch(request)
                for item in results {
                    context.delete(item)
                }
                if !results.isEmpty {
                    try context.save()
                    print("Removed from index: \(path)")
                }
            } catch {
                print("Error deleting file at \(path): \(error)")
            }
        }

        await SearchService.shared.remove(path: path)
    }

    public func clearIndex(path: String? = nil) async {
        // Strictly use the provided path. Do not resolve symlinks.
        let resolvedPath = path
        let context = self.context

        let success = await context.perform {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = FileItem.fetchRequest()

            if let path = resolvedPath {
                fetchRequest.predicate = NSPredicate(format: "path BEGINSWITH %@", path)
            }

            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)

            do {
                try context.execute(deleteRequest)
                try context.save()
                print("Index cleared for path: \(resolvedPath ?? "All")")
                return true
            } catch {
                print("Error clearing index: \(error)")
                return false
            }
        }

        if success {
            if let path = resolvedPath {
                await SearchService.shared.remove(prefix: path)
            } else {
                await SearchService.shared.clear()
            }
        }
    }
}

extension FileItem {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<FileItem> {
        return NSFetchRequest<FileItem>(entityName: "FileItem")
    }
}
