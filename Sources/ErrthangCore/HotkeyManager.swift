import Cocoa
import Carbon

@MainActor
public class HotkeyManager {
    public static let shared = HotkeyManager()

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    private init() {
        print("HotkeyManager: Initializing...")
        installEventHandler()
    }

    public func registerGlobalHotkey() {
        print("HotkeyManager: registerGlobalHotkey called")
        // ID 1 is reserved for Global Hotkey
        guard let config = ConfigManager.shared.config.globalHotkey else {
            print("HotkeyManager: No global hotkey config found")
            unregister(id: 1)
            return
        }

        print("HotkeyManager: Registering global hotkey with code \(config.keyCode)")
        register(id: 1, config: config) {
            Task { @MainActor in
                print("HotkeyManager: Global hotkey triggered! Activating app...")
                HotkeyManager.activateMainApp()
            }
        }
    }

    private static func activateMainApp() {
        print("Activation: Request received.")

        // 1. If we are the main app (Regular activation policy), activate self
        if NSApp.activationPolicy() == .regular {
            print("Activation: Policy is regular, activating self.")
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

            if let window = NSApplication.shared.windows.first {
                window.makeKeyAndOrderFront(nil)
            } else {
                print("Activation: No windows found to activate!")
            }
            return
        }

        print("Activation: Policy is not regular (likely service). Searching for main app...")
        // 2. We are likely the service (Accessory/Prohibited policy). Find the main app.
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications

        // Try to find by name "errthang" (excluding "errthang-service")
        // Check both localized name and bundle identifier
        if let app = apps.first(where: {
            let name = $0.localizedName?.lowercased() ?? ""
            return name == "errthang"
        }) {
            print("Activation: Found running app: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "no-bundle-id"))")

            // Unhide first
            app.unhide()

            // Try different activation options
            let success = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            print("Activation: activate() returned \(success)")
        } else {
            print("Activation: Main app not found running. Available apps: \(apps.map { $0.localizedName ?? "" }.filter { $0.lowercased().contains("err") })")
            print("Activation: Attempting launch...")

            // 3. Not running? Launch it.
            // Assume "errthang" executable is in the same directory as this service executable
            guard let myPath = Bundle.main.executableURL?.deletingLastPathComponent() else {
                print("Activation: Could not determine executable path")
                return
            }

            // Prefer launching the App Bundle if we are inside one
            var appURL = myPath.appendingPathComponent("errthang")
            let bundleURL = myPath.deletingLastPathComponent().deletingLastPathComponent()

            if bundleURL.pathExtension == "app" {
                appURL = bundleURL
            }

            // Check if it exists
            if FileManager.default.fileExists(atPath: appURL.path) {
                print("Activation: Launching \(appURL.path)")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                workspace.openApplication(at: appURL, configuration: config) { app, error in
                    if let error = error {
                        print("Activation: Launch failed: \(error)")
                    } else {
                        print("Activation: Launch successful")
                    }
                }
            } else {
                print("Activation: Could not find errthang app/executable at \(appURL.path)")
            }
        }
    }

    public func register(id: UInt32, config: HotkeyConfig, handler: @escaping () -> Void) {
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: OSType(0x45525254), id: id) // 'ERRT'
        let carbonModifiers = convertToCarbonModifiers(config.modifiers)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(config.keyCode),
                                       carbonModifiers,
                                       hotKeyID,
                                       GetApplicationEventTarget(),
                                       0,
                                       &ref)

        if status == noErr, let ref = ref {
            hotKeys[id] = ref
            handlers[id] = handler
            print("Successfully registered hotkey ID \(id): code=\(config.keyCode), mods=\(config.modifiers) (Carbon: \(carbonModifiers))")
        } else {
            print("Failed to register hotkey ID \(id): \(status)")
        }
    }

    public func unregister(id: UInt32) {
        if let ref = hotKeys[id] {
            UnregisterEventHotKey(ref)
            hotKeys.removeValue(forKey: id)
            handlers.removeValue(forKey: id)
        }
    }

    public func handleEvent(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandler() {
        print("Installing Carbon Event Handler...")
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            // print("Received Carbon Event") // Commented out to avoid spam, but useful if needed
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                         EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID),
                                         nil,
                                         MemoryLayout<EventHotKeyID>.size,
                                         nil,
                                         &hotKeyID)

            if status == noErr {
                print("Global Hotkey Triggered: ID \(hotKeyID.id)")
                Task { @MainActor in
                    HotkeyManager.shared.handleEvent(id: hotKeyID.id)
                }
            } else {
                print("Failed to get hotkey ID from event: \(status)")
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                          handler,
                          1,
                          &eventType,
                          nil,
                          &eventHandlerRef)
    }

    // We need to keep a reference to the handler to prevent it from being deallocated if it were an object,
    // but here it's a C function pointer so it's fine.
    // However, we need to store the EventHandlerRef to remove it later if needed (though singleton lives forever).
    private var eventHandlerRef: EventHandlerRef?

    public func requestAccessibilityPermissions() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    nonisolated private func checkAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func convertToNSEventModifiers(_ carbon: UInt32) -> UInt {
        var flags: NSEvent.ModifierFlags = []

        if (carbon & UInt32(cmdKey)) != 0 { flags.insert(.command) }
        if (carbon & UInt32(optionKey)) != 0 { flags.insert(.option) }
        if (carbon & UInt32(controlKey)) != 0 { flags.insert(.control) }
        if (carbon & UInt32(shiftKey)) != 0 { flags.insert(.shift) }

        return flags.rawValue
    }

    private func convertToCarbonModifiers(_ modifiers: UInt) -> UInt32 {
        var carbon: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)

        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        return carbon
    }
}
