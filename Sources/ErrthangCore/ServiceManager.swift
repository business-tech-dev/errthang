import Foundation
import ServiceManagement
import AppKit

@MainActor
public class ServiceManager: ObservableObject {
    public static let shared = ServiceManager()

    private var scanTimer: Timer?

    private init() {}

    // MARK: - Service Management

    public func setServiceEnabled(_ enabled: Bool) {
        if enabled {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
    }

    private func installLaunchAgent() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsDir.appendingPathComponent("com.businesstechdev.errthang.service.plist")

        // Ensure LaunchAgents directory exists
        if !fileManager.fileExists(atPath: launchAgentsDir.path) {
            try? fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        }

        // Determine path to errthang-service executable
        // Assuming it lives alongside the main application executable
        guard let mainExecURL = Bundle.main.executableURL else {
            print("Could not locate main executable.")
            return
        }

        let serviceExecURL = mainExecURL.deletingLastPathComponent().appendingPathComponent("errthang-service")

        // Plist content
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.businesstechdev.errthang.service</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(serviceExecURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(home.path)/.config/errthang/service.log</string>
            <key>StandardErrorPath</key>
            <string>\(home.path)/.config/errthang/service.err</string>
        </dict>
        </plist>
        """

        do {
            try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)

            // Load the agent
            runCommand("/bin/launchctl", args: ["bootstrap", "gui/\(getuid())", plistURL.path])
            // Also try legacy load just in case (bootstrap is preferred on newer macOS but load is common fallback mental model, though bootstrap covers it)
            // actually bootstrap is correct for user agents.

            print("Installed and loaded LaunchAgent at \(plistURL.path)")
        } catch {
            print("Failed to install LaunchAgent: \(error)")
        }
    }

    private func removeLaunchAgent() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/com.businesstechdev.errthang.service.plist")
        let serviceLabel = "com.businesstechdev.errthang.service"

        // Always try to unload the service by label, regardless of file existence
        // This ensures that if the file was deleted but service is stuck, we still kill it.
        runCommand("/bin/launchctl", args: ["bootout", "gui/\(getuid())/\(serviceLabel)"])

        // Also try bootout by path if file exists, just in case (though label should be sufficient)
        if fileManager.fileExists(atPath: plistURL.path) {
             // We already booted out by label, but if that failed for some reason and path works...
             // Actually, bootout by label is the robust way.

             try? fileManager.removeItem(at: plistURL)
             print("Removed LaunchAgent at \(plistURL.path)")
        } else {
             print("LaunchAgent plist not found at \(plistURL.path), skipping file removal.")
        }
    }

    private func runCommand(_ command: String, args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = args

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), !output.isEmpty {
            print("Command output: \(output)")
        }

        if task.terminationStatus != 0 {
             print("Command failed with status \(task.terminationStatus): \(command) \(args.joined(separator: " "))")
        }
    }

    // MARK: - Background Scanning

    public func setup() {
        // Enable Hotkeys ONLY if the background service is NOT enabled.
        // If the service is enabled, it handles the hotkey registration.
        if !ConfigManager.shared.config.startOnBoot {
            HotkeyManager.shared.registerGlobalHotkey()
        }
    }

    public func scheduleNextScan() {
        scanTimer?.invalidate()
        scanTimer = nil

        // Only schedule if Start on Boot is enabled
        guard ConfigManager.shared.config.startOnBoot else { return }

        // Default to 3:00 AM if not specifically set
        let scheduledTime = ConfigManager.shared.config.scheduledScanTime ?? Calendar.current.date(from: DateComponents(hour: 3, minute: 0)) ?? Date()

        let calendar = Calendar.current
        let now = Date()

        // Extract hour/minute from scheduledTime
        let components = calendar.dateComponents([.hour, .minute], from: scheduledTime)

        // Create date for today with that time
        guard let todayDate = calendar.date(bySettingHour: components.hour ?? 0, minute: components.minute ?? 0, second: 0, of: now) else { return }

        var nextFireDate = todayDate
        if nextFireDate <= now {
            // If passed today, schedule for tomorrow
            nextFireDate = calendar.date(byAdding: .day, value: 1, to: nextFireDate)!
        }

        print("Scheduling next background scan for: \(nextFireDate)")

        let timer = Timer(fire: nextFireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performBackgroundScan()
                self?.scheduleNextScan() // Reschedule for next day
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    public func performBackgroundScan() async {
        print("Starting background scan...")

        // 1. Index Home
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        // We need a background context indexer
        let context = PersistenceController.shared.newBackgroundContext()
        let indexer = FileIndexer(context: context)

        // Note: indexer.index(path:) clears existing index for that path first, which is what we want for a full re-scan/update.
        // However, users might prefer an "update" rather than "re-index".
        // But FileIndexer.index is designed as a re-crawl.
        // Given the requirement "scans Saved Paths and home", a re-crawl ensures consistency.

        await indexer.index(path: homePath)

        // 2. Index Saved Paths
        let savedShares = ConfigManager.shared.config.smbShares
        for share in savedShares {
            if let url = URL(string: share.url) {
                var pathToIndex: String?

                if url.isFileURL {
                    pathToIndex = url.path
                } else if let mountPath = share.mountPath {
                    pathToIndex = mountPath
                }

                if let path = pathToIndex {
                    await indexer.index(path: path)
                }
            }
        }

        print("Background scan complete.")
    }
}
