import SwiftUI
import ErrthangCore
import CoreData

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            PathsSettingsView()
                .tabItem {
                    Label("Paths", systemImage: "server.rack")
                }
            ServiceSettingsView()
                .tabItem {
                    Label("Service", systemImage: "gearshape.2")
                }
        }
        .frame(width: 500)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var configManager = ConfigManager.shared
    @State private var showingFileImporter = false
    @State private var showingDeleteConfirmation = false
    @State private var isIndexing = false
    @State private var indexingTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Appearance Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance")
                    .font(.headline)

                Picker("", selection: $configManager.config.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: configManager.config.appearance) { _, _ in
                    configManager.save()
                }
            }

            // Global Hotkey Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Global Hotkey")
                    .font(.headline)

                HStack {
                    Text("Open Errthang:")
                    Spacer()
                    HotkeyRecorder(config: $configManager.config.globalHotkey)
                }
            }

            // Excluded Paths Section
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Paths")
                        .font(.headline)
                    Text("Files and folders in these paths will be ignored during indexing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                List {
                    ForEach(configManager.config.excludedPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                            Text(path)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                removePath(path)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )

                Button("Add Path...") {
                    showingFileImporter = true
                }
            }

            // Indexing Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Indexing")
                    .font(.headline)

                Button(action: indexHome) {
                    HStack {
                        if isIndexing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isIndexing ? "Indexing Home..." : "Re-Index Home")
                    }
                }
                .disabled(isIndexing)
                .help("Clears and re-indexes only the Home directory")
            }

            // Danger Zone
            VStack(alignment: .leading, spacing: 12) {
                Text("Danger Zone")
                    .font(.headline)
                    .foregroundColor(.red)

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete Entire Index")
                    }
                }
                .alert("Delete Entire Index?", isPresented: $showingDeleteConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        deleteEntireIndex()
                    }
                } message: {
                    Text("This will remove all indexed files and clear the database. This action cannot be undone.")
                }
            }

            Spacer()
        }
        .padding(24)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    addPath(url.path)
                }
            case .failure(let error):
                print("Failed to select path: \(error.localizedDescription)")
            }
        }
    }

    private func addPath(_ path: String) {
        if !configManager.config.excludedPaths.contains(path) {
            configManager.config.excludedPaths.append(path)
            configManager.save()
        }
    }

    private func removePath(_ path: String) {
        configManager.config.excludedPaths.removeAll(where: { $0 == path })
        configManager.save()
    }

    private func indexHome() {
        indexingTask?.cancel()

        isIndexing = true
        let backgroundContext = PersistenceController.shared.newBackgroundContext()
        let indexer = FileIndexer(context: backgroundContext)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        // Start monitoring for real-time updates
        FileMonitor.shared.startMonitoring(path: homePath)

        indexingTask = Task {
            await indexer.clearIndex(path: homePath)

            if !Task.isCancelled {
                await indexer.index(path: homePath)
            }

            if !Task.isCancelled {
                await MainActor.run {
                    isIndexing = false
                }
            }
        }
    }

    private func deleteEntireIndex() {
        // Cancel local task
        indexingTask?.cancel()
        indexingTask = nil
        isIndexing = false

        Task {
            // 1. Cancel any running indexing operations
            await SearchService.shared.cancelIndexing()

            // 2. Stop monitoring to prevent new events
            await MainActor.run {
                FileMonitor.shared.stopMonitoring()
            }

            // 3. Clear the index
            let backgroundContext = PersistenceController.shared.newBackgroundContext()
            let indexer = FileIndexer(context: backgroundContext)
            await indexer.clearIndex()
        }
    }
}

struct HotkeyRecorder: View {
    @Binding var config: HotkeyConfig?
    @State private var isRecording = false

    var body: some View {
        HStack {
            if isRecording {
                KeyRecordingView { keyCode, modifiers in
                    // Completion
                    if let code = keyCode {
                        // Key recorded
                        let newConfig = HotkeyConfig(keyCode: code, modifiers: modifiers)
                        self.config = newConfig
                        ConfigManager.shared.save()
                    }
                    // If nil, it was cancelled (Esc)
                    
                    self.isRecording = false
                    // Re-register global hotkey
                    HotkeyManager.shared.registerGlobalHotkey()
                }
                .frame(width: 140, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                )
            } else {
                Button {
                    // Start recording
                    HotkeyManager.shared.unregister(id: 1)
                    isRecording = true
                } label: {
                    Text(displayText)
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var displayText: String {
        guard let config = config else { return "Record Shortcut" }
        return "\(modifierString(config.modifiers)) \(keyString(config.keyCode))"
    }

    private func modifierString(_ modifiers: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private func keyString(_ keyCode: Int) -> String {
        // Simple mapping for common keys
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 49: return "Space"
        case 50: return "`"
        case 53: return "Esc"
        default: return "Key(\(keyCode))"
        }
    }
}

struct KeyRecordingView: NSViewRepresentable {
    var onComplete: (Int?, UInt) -> Void

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.onComplete = onComplete
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        // Ensure it becomes first responder when shown
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    class KeyRecorderNSView: NSView {
        var onComplete: ((Int?, UInt) -> Void)?
        private var currentModifiers: NSEvent.ModifierFlags = []

        override var acceptsFirstResponder: Bool { true }
        
        // Draw a placeholder or current modifiers
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            
            let text: String
            if currentModifiers.isEmpty {
                text = "Type Key..."
            } else {
                text = modifierString(currentModifiers)
            }
            
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            
            let size = text.size(withAttributes: attrs)
            let point = NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2)
            
            text.draw(at: point, withAttributes: attrs)
        }
        
        private func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
            var result = ""
            if flags.contains(.control) { result += "⌃" }
            if flags.contains(.option) { result += "⌥" }
            if flags.contains(.shift) { result += "⇧" }
            if flags.contains(.command) { result += "⌘" }
            return result
        }

        override func keyDown(with event: NSEvent) {
            let keyCode = Int(event.keyCode)
            
            // Cancel on Escape
            if keyCode == 53 {
                onComplete?(nil, 0)
                return
            }
            
            // Extract modifiers
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            
            // Ignore if it's just a modifier key press (though usually keyDown doesn't fire for mod-only?)
            // Actually keyDown DOES fire for some keys.
            // But we want to record the combo.
            
            onComplete?(keyCode, flags.rawValue)
        }
        
        override func flagsChanged(with event: NSEvent) {
            currentModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            needsDisplay = true
        }
        
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Capture all key equivalents (Cmd+Key, etc)
            keyDown(with: event)
            return true
        }
    }
}

struct PathsSettingsView: View {
    @ObservedObject var smbManager = SMBManager.shared
    @ObservedObject var configManager = ConfigManager.shared
    @State private var smbURL = "smb://"
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showingShareImporter = false
    @State private var indexingShares: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Connect to Server Section
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to Server")
                        .font(.headline)
                    Text("smb://server/share")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    TextField("", text: $smbURL, prompt: Text("smb://192.168.1.100/share"))
                        .textFieldStyle(.roundedBorder)

                    Button("Connect") {
                        connectToSMB()
                    }
                    .disabled(isConnecting)
                }

                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            // Add Connected Share Section
            let unsavedShares = smbManager.connectedShares.filter { share in
                !configManager.config.smbShares.contains { saved in
                    saved.url == share.url.absoluteString
                }
            }

            if !unsavedShares.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add Connected Path")
                        .font(.headline)

                    VStack(spacing: 0) {
                        ForEach(unsavedShares) { share in
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "server.rack")
                                    VStack(alignment: .leading) {
                                        Text(share.url.lastPathComponent)
                                        if let host = share.url.host {
                                            Text(host)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Button("Add") {
                                        configManager.addSMBShare(url: share.url.absoluteString, mountPath: share.mountPath)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)

                                if share.id != unsavedShares.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            }

            // Saved Paths Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved Paths")
                    .font(.headline)

                if configManager.config.smbShares.isEmpty {
                    Text("No paths saved")
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach($configManager.config.smbShares, id: \.url) { $share in
                            VStack(spacing: 0) {
                                HStack {
                                    Image(systemName: "server.rack")
                                    VStack(alignment: .leading) {
                                        if share.url.hasPrefix("file://") {
                                            Text(share.mountPath ?? share.url)
                                        } else {
                                            Text(share.url)
                                            if let path = share.mountPath {
                                                Text(path)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                    }

                                    Spacer()

                                    Button {
                                        indexShare(share)
                                    } label: {
                                        if indexingShares.contains(share.url) {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                        }
                                    }
                                    .disabled(indexingShares.contains(share.url))
                                    .help("Re-index Path")
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        removeSavedPath(share)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)

                                if share.url != configManager.config.smbShares.last?.url {
                                    Divider()
                                }
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                Button("Add Path...") {
                    showingShareImporter = true
                }
            }

            Spacer()
        }
        .padding(24)
        .fileImporter(
            isPresented: $showingShareImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Start accessing the security scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        // Handle failure
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    configManager.addSMBShare(url: url.absoluteString, mountPath: url.path)
                }
            case .failure(let error):
                print("Failed to select path: \(error.localizedDescription)")
            }
        }
    }

    private func connectToSMB() {
        guard let url = URL(string: smbURL) else {
            errorMessage = "Invalid URL"
            return
        }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let mountPath = try await smbManager.connect(to: url)
                print("Connected to \(mountPath)")

                // Save to config
                configManager.addSMBShare(url: smbURL, mountPath: mountPath)

                // Trigger indexing if enabled (handled by main app or observer, but we can trigger here if needed)
                // For now, let's just ensure it's saved.

                isConnecting = false
                smbURL = "smb://"
            } catch {
                isConnecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeSavedPath(_ share: SMBShareConfig) {
        if let path = share.mountPath {
            smbManager.disconnect(path: path)

            // Remove indexed files for this path
            Task {
                let backgroundContext = PersistenceController.shared.newBackgroundContext()
                let indexer = FileIndexer(context: backgroundContext)
                await indexer.clearIndex(path: path)
            }
        }
        configManager.removeSMBShare(url: share.url)
    }

    private func indexShare(_ share: SMBShareConfig) {
        guard let url = URL(string: share.url) else { return }

        indexingShares.insert(share.url)

        Task {
            // For shares, we need the mount path. If it's saved but not mounted, we might need to connect first?
            // Assuming it's mounted if we are re-indexing.
            // If mountPath is nil, try to find it or connect?

            var mountPath = share.mountPath

            if url.isFileURL {
                mountPath = url.path
            } else if mountPath == nil {
                // Try to connect to get mount path
                _ = try? await SMBManager.shared.connect(to: url)
                // Retrieve updated mount path from SMBManager or Config
                // Since connect updates config implicitly in our other code, but we should be careful.
                // Let's just check if SMBManager has it connected.
                if let connected = SMBManager.shared.connectedShares.first(where: { $0.url == url }) {
                    mountPath = connected.mountPath

                    // Update config
                    await MainActor.run {
                        configManager.addSMBShare(url: share.url, mountPath: mountPath)
                    }
                }
            }

            if let path = mountPath {
                let backgroundContext = PersistenceController.shared.newBackgroundContext()
                let indexer = FileIndexer(context: backgroundContext)
                await indexer.index(path: path)
            }

            await MainActor.run {
                _ = indexingShares.remove(share.url)
            }
        }
    }
}

struct ServiceSettingsView: View {
    @ObservedObject var configManager = ConfigManager.shared
    @ObservedObject var serviceManager = ServiceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Startup Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Startup")
                    .font(.headline)

                Toggle("Run errthang background service", isOn: Binding(
                    get: { configManager.config.startOnBoot },
                    set: { newValue in
                        configManager.config.startOnBoot = newValue
                        configManager.save()
                        serviceManager.setServiceEnabled(newValue)

                        // Update local hotkey registration state
                        if newValue {
                            // Service enabled: Service takes over. Main app unregisters to avoid conflict.
                            HotkeyManager.shared.unregister(id: 1)
                        } else {
                            // Service disabled: Main app takes over.
                            HotkeyManager.shared.registerGlobalHotkey()
                        }

                        // Enforce logic: if service is enabled, ensure default time is set
                        if newValue {
                            // Ensure a default time is set if nil
                            if configManager.config.scheduledScanTime == nil {
                                let defaultDate = Calendar.current.date(from: DateComponents(hour: 3, minute: 0)) ?? Date()
                                configManager.config.scheduledScanTime = defaultDate
                            }
                            configManager.save()
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            // Scheduled Scanning Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Scheduled Scanning")
                    .font(.headline)
                    .foregroundColor(configManager.config.startOnBoot ? .primary : .secondary)

                HStack {
                    Text("Daily Background Scan:")
                        .foregroundColor(configManager.config.startOnBoot ? .primary : .secondary)

                    DatePicker("", selection: Binding(
                        get: {
                            configManager.config.scheduledScanTime ?? Calendar.current.date(from: DateComponents(hour: 3, minute: 0)) ?? Date()
                        },
                        set: { newDate in
                            configManager.config.scheduledScanTime = newDate
                            configManager.save()
                            // We don't need to manually reschedule here; the service (if running)
                            // checks config or we could signal it.
                            // For MVP, if the user changes time, they might need to restart service or
                            // we rely on the service checking config periodically?
                            // The service currently only schedules on launch.
                            // To make it robust, the service should watch for config changes or we restart it.

                            // Simplest way: Restart the agent if enabled.
                            if configManager.config.startOnBoot {
                                serviceManager.setServiceEnabled(false) // Unload
                                serviceManager.setServiceEnabled(true)  // Load (picking up new config/time)
                            }
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(!configManager.config.startOnBoot)
                }
                .padding(.leading, 24)

                if !configManager.config.startOnBoot {
                    Text("Requires 'Run errthang background service' to be enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)
                }
            }

            Spacer()
        }
        .padding(24)
    }
}
