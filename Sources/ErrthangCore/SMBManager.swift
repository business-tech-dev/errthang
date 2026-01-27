import Foundation
import NetFS

@MainActor
public class SMBManager: ObservableObject {
    public static let shared = SMBManager()

    public struct ConnectedShare: Hashable, Identifiable {
        public let id: String // mountPath
        public let url: URL
        public let mountPath: String

        public init(url: URL, mountPath: String) {
            self.url = url
            self.mountPath = mountPath
            self.id = mountPath
        }
    }

    @Published public var connectedShares: [ConnectedShare] = []

    public func connect(to url: URL, username: String? = nil, password: String? = nil) async throws -> String {
        print("Connecting to \(url)")

        return try await withCheckedThrowingContinuation { continuation in
            var mountPoints: Unmanaged<CFArray>?

            // Prepare options if needed
            let openOptions = NSMutableDictionary()
            openOptions.setObject(true, forKey: "NoUI" as NSString)
            openOptions.setObject(true, forKey: "NoAuth" as NSString) // Try to suppress auth prompt as well

            let mountOptions = NSMutableDictionary()
            // We can add options like kNetFSAllowSubMountsKey if needed

            // Handle authentication if provided (though NetFS usually handles UI prompts)
            // If we wanted to pass credentials programmatically we might need to use the URL string format:
            // smb://user:password@host/share

            var connectionURL = url
            if let user = username, let pass = password,
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.user = user
                components.password = pass
                if let newURL = components.url {
                    connectionURL = newURL
                }
            }

            let result = NetFSMountURLSync(
                connectionURL as CFURL,
                nil, // mountpath - nil means default location (/Volumes)
                nil, // user
                nil, // password
                openOptions, // open_options
                mountOptions, // mount_options
                &mountPoints // mountpoints
            )

            if result == 0, let mounts = mountPoints?.takeRetainedValue() as? [String], let mountPath = mounts.first {
                print("Mounted at: \(mountPath)")

                // Add to connected shares if not already present
                let share = ConnectedShare(url: url, mountPath: mountPath)
                if !self.connectedShares.contains(where: { $0.mountPath == mountPath }) {
                    self.connectedShares.append(share)
                }

                continuation.resume(returning: mountPath)
            } else {
                let error = NSError(domain: "SMBManager", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Failed to mount SMB share"])
                continuation.resume(throwing: error)
            }
        }
    }

    public func disconnect(path: String) {
        // Unmounting usually handled by Finder/System, but we could use unmount() syscall or NetFS unmount if available (NetFS doesn't have a public UnmountSync equivalent easily accessible in Swift without bridging headers usually, but we can try FS operations)
        // For now, we'll just remove from our list
        if let index = connectedShares.firstIndex(where: { $0.mountPath == path }) {
            connectedShares.remove(at: index)
        }
    }
}
