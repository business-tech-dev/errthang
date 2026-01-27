import Foundation
import CoreData

@objc(FileItem)
public class FileItem: NSManagedObject {
    @NSManaged public var isDirectory: Bool
    @NSManaged public var modificationDate: Date?
    @NSManaged public var name: String?
    @NSManaged public var path: String?
    @NSManaged public var size: Int64
}

extension FileItem: Identifiable {
    public var id: String { path ?? UUID().uuidString }
}
