import Foundation

public struct SMBShareConfig: Codable, Hashable {
    public let url: String
    public var mountPath: String?

    public init(url: String, mountPath: String? = nil) {
        self.url = url
        self.mountPath = mountPath
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    public var id: String { self.rawValue }
}

public enum SidebarVisibility: String, Codable {
    case all
    case detailOnly
}

public struct SortConfig: Codable, Equatable {
    public var key: String
    public var isAscending: Bool

    public init(key: String = "name", isAscending: Bool = true) {
        self.key = key
        self.isAscending = isAscending
    }
}

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: Int
    public var modifiers: UInt

    public init(keyCode: Int, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct AppConfig: Codable {
    public var smbShares: [SMBShareConfig] = []
    public var excludedPaths: [String] = []
    public var searchHistory: [String] = []
    public var pinnedSearches: [String] = []
    public var appearance: AppearanceMode = .system
    public var sidebarVisibility: SidebarVisibility = .all
    public var sortConfig: SortConfig = SortConfig()
    public var rememberWindowPosition: Bool = true
    public var windowFrame: String?
    public var globalHotkey: HotkeyConfig?
    public var startOnBoot: Bool = false
    public var scheduledScanTime: Date?

    public init() {}
}

@MainActor
public class ConfigManager: ObservableObject {
    public static let shared = ConfigManager()
    @Published public var config: AppConfig = AppConfig()

    private let configURL: URL

    private init() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let configDir = home.appendingPathComponent(".config/errthang")

        if !fileManager.fileExists(atPath: configDir.path) {
            try? fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        self.configURL = configDir.appendingPathComponent("config.json")
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return
        }

        self.config = decoded
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL)

        // Notify other processes (like the background service)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.businesstechdev.errthang.configChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - SMB Shares

    public func addSMBShare(url: String, mountPath: String?) {
        if let index = config.smbShares.firstIndex(where: { $0.url == url }) {
            // Update existing
            config.smbShares[index].mountPath = mountPath
        } else {
            // Add new
            config.smbShares.append(SMBShareConfig(url: url, mountPath: mountPath))
        }
        save()
    }

    public func removeSMBShare(url: String) {
        config.smbShares.removeAll(where: { $0.url == url })
        save()
    }

    // MARK: - Search History & Pinned

    public func addSearchHistory(_ term: String) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Remove if exists to move to top
        config.searchHistory.removeAll(where: { $0 == term })

        // Add to front
        config.searchHistory.insert(term, at: 0)

        // Cap at 50 items
        if config.searchHistory.count > 50 {
            config.searchHistory = Array(config.searchHistory.prefix(50))
        }
        save()
    }

    public func togglePinSearch(_ term: String) {
        if config.pinnedSearches.contains(term) {
            config.pinnedSearches.removeAll(where: { $0 == term })
        } else {
            config.pinnedSearches.append(term)
        }
        save()
    }

    public func isPinned(_ term: String) -> Bool {
        config.pinnedSearches.contains(term)
    }

    public func clearHistory() {
        config.searchHistory.removeAll()
        save()
    }
}
