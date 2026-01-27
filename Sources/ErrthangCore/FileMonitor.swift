import Foundation
import CoreServices

@MainActor
public class FileMonitor: ObservableObject {
    public static let shared = FileMonitor()

    @Published public var isIndexing = false

    private var streamRef: FSEventStreamRef?
    private var indexer: FileIndexer?
    private var monitoredPaths: Set<String> = []

    private init() {
    }

    public func setup() {
        if indexer == nil {
            let context = PersistenceController.shared.newBackgroundContext()
            indexer = FileIndexer(context: context)
        }
    }

    public func startMonitoring(path: String) {
        setup()
        if monitoredPaths.contains(path) { return }

        print("Adding path to monitor: \(path)")
        monitoredPaths.insert(path)
        restartStream()
    }

    public func stopMonitoring(path: String) {
        if monitoredPaths.contains(path) {
            print("Removing path from monitor: \(path)")
            monitoredPaths.remove(path)
            restartStream()
        }
    }

    private func restartStream() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }

        if monitoredPaths.isEmpty {
            isIndexing = false
            return
        }

        let pathsToWatch = Array(monitoredPaths) as CFArray

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let monitor = Unmanaged<FileMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]

            Task {
                await monitor.handleEvents(paths: paths)
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)

        streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        )

        if let stream = streamRef {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            isIndexing = true
        }
    }

    public func handleEvents(paths: [String]) async {
        if !isIndexing { return }

        guard let indexer = indexer else { return }

        // Fetch excluded paths (accessing ConfigManager on MainActor)
        let excludedPaths = ConfigManager.shared.config.excludedPaths

        for path in paths {
            // Check exclusions
            if excludedPaths.contains(where: { path.hasPrefix($0) }) {
                continue
            }

            await indexer.updateItem(at: path)
        }
    }

    public func stopMonitoring() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            isIndexing = false
        }
        monitoredPaths.removeAll()
    }
}
