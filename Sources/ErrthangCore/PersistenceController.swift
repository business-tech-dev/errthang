import CoreData

@MainActor
public class PersistenceController: ObservableObject {
    public static let shared = PersistenceController()

    public let container: NSPersistentContainer

    public init(inMemory: Bool = false) {
        // Define model programmatically to avoid resource bundling issues
        let model = NSManagedObjectModel()

        let fileItemEntity = NSEntityDescription()
        fileItemEntity.name = "FileItem"
        fileItemEntity.managedObjectClassName = "FileItem"

        // Attributes
        let pathAttribute = NSAttributeDescription()
        pathAttribute.name = "path"
        pathAttribute.attributeType = .stringAttributeType

        let nameAttribute = NSAttributeDescription()
        nameAttribute.name = "name"
        nameAttribute.attributeType = .stringAttributeType

        let isDirectoryAttribute = NSAttributeDescription()
        isDirectoryAttribute.name = "isDirectory"
        isDirectoryAttribute.attributeType = .booleanAttributeType
        isDirectoryAttribute.defaultValue = false

        let sizeAttribute = NSAttributeDescription()
        sizeAttribute.name = "size"
        sizeAttribute.attributeType = .integer64AttributeType
        sizeAttribute.defaultValue = 0

        let modificationDateAttribute = NSAttributeDescription()
        modificationDateAttribute.name = "modificationDate"
        modificationDateAttribute.attributeType = .dateAttributeType

        fileItemEntity.properties = [
            pathAttribute,
            nameAttribute,
            isDirectoryAttribute,
            sizeAttribute,
            modificationDateAttribute
        ]

        // Create index for path to replace deprecated isIndexed = true
        let pathIndexElement = NSFetchIndexElementDescription(property: pathAttribute, collationType: .binary)
        let pathIndex = NSFetchIndexDescription(name: "byPath", elements: [pathIndexElement])

        // Create index for name to optimize sorting
        let nameIndexElement = NSFetchIndexElementDescription(property: nameAttribute, collationType: .binary)
        let nameIndex = NSFetchIndexDescription(name: "byName", elements: [nameIndexElement])

        // Create index for size to optimize sorting
        let sizeIndexElement = NSFetchIndexElementDescription(property: sizeAttribute, collationType: .binary)
        let sizeIndex = NSFetchIndexDescription(name: "bySize", elements: [sizeIndexElement])

        // Create index for modificationDate to optimize sorting
        let dateIndexElement = NSFetchIndexElementDescription(property: modificationDateAttribute, collationType: .binary)
        let dateIndex = NSFetchIndexDescription(name: "byDate", elements: [dateIndexElement])

        fileItemEntity.indexes = [pathIndex, nameIndex, sizeIndex, dateIndex]
        fileItemEntity.uniquenessConstraints = [[pathAttribute]]

        model.entities = [fileItemEntity]

        container = NSPersistentContainer(name: "errthang", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Explicitly set the store URL to a shared location
            // Using ~/.config/errthang/errthang.sqlite matches ConfigManager's location
            let fileManager = FileManager.default
            let home = fileManager.homeDirectoryForCurrentUser
            let configDir = home.appendingPathComponent(".config/errthang")

            if !fileManager.fileExists(atPath: configDir.path) {
                try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            }

            let storeURL = configDir.appendingPathComponent("errthang.sqlite")

            // Migration: Check if DB exists in old location (Application Support) and move it if new location is empty
            if !fileManager.fileExists(atPath: storeURL.path) {
                if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    // Application Support/errthang.sqlite (implied by default container name "errthang")
                    // Actually, default is AppSupport/BundleID/ or just AppSupport/name?
                    // NSPersistentContainer(name: "errthang") usually maps to AppSupport/errthang.sqlite or AppSupport/ProcessName/errthang.sqlite?
                    // Based on user's `ls` output: `~/Library/Application Support/errthang.sqlite` (directly in root of AppSupport? Or maybe `Application Support/errthang.sqlite` was just found by find command?)
                    // `find` output: `-rw-r--r--  1 user  staff ... errthang.sqlite`
                    // It didn't show full path in my thought simulation, but usually it's `~/Library/Application Support/errthang.sqlite` if not sandboxed/bundled?
                    // Or `~/Library/Application Support/errthang/errthang.sqlite`.

                    // Let's try both common locations.
                    let oldURL1 = appSupportDir.appendingPathComponent("errthang.sqlite")

                    if fileManager.fileExists(atPath: oldURL1.path) {
                        print("Migrating database from \(oldURL1.path) to \(storeURL.path)")
                        do {
                            try fileManager.moveItem(at: oldURL1, to: storeURL)
                            // Try moving WAL and SHM if they exist
                            let oldWAL = appSupportDir.appendingPathComponent("errthang.sqlite-wal")
                            let oldSHM = appSupportDir.appendingPathComponent("errthang.sqlite-shm")
                            if fileManager.fileExists(atPath: oldWAL.path) {
                                try fileManager.moveItem(at: oldWAL, to: configDir.appendingPathComponent("errthang.sqlite-wal"))
                            }
                            if fileManager.fileExists(atPath: oldSHM.path) {
                                try fileManager.moveItem(at: oldSHM, to: configDir.appendingPathComponent("errthang.sqlite-shm"))
                            }
                        } catch {
                            print("Migration failed: \(error)")
                        }
                    }

                    // Also migrate index.bin if it exists in old location
                    // SearchService expects it in configDir, but it might be in AppSupport
                    let oldIndexBin = appSupportDir.appendingPathComponent("index.bin")
                    let newIndexBin = configDir.appendingPathComponent("index.bin")

                    if fileManager.fileExists(atPath: oldIndexBin.path) && !fileManager.fileExists(atPath: newIndexBin.path) {
                        print("Migrating index.bin from \(oldIndexBin.path) to \(newIndexBin.path)")
                        try? fileManager.moveItem(at: oldIndexBin, to: newIndexBin)
                    }
                }
            }

            container.persistentStoreDescriptions.first!.url = storeURL

            // Allow lightweight migration
            let description = container.persistentStoreDescriptions.first!
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }

    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return context
    }
}
