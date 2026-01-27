import Foundation
import ErrthangCore
import CoreData

// Enable line buffering for stdout/stderr to ensure logs appear immediately
setbuf(__stdoutp, nil)
setbuf(__stderrp, nil)

// Main entry point for the background service
import AppKit

// Ensure NSApplication is initialized to connect to Window Server
// This is required for Carbon Hotkeys and NSWorkspace to work properly.
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Run as background app (no Dock icon)

print("Errthang Service starting...")

// Force early initialization of singletons
_ = PersistenceController.shared
_ = ConfigManager.shared

print("Config loaded. Hotkey present: \(ConfigManager.shared.config.globalHotkey != nil)")
if let hotkey = ConfigManager.shared.config.globalHotkey {
    print("Hotkey Config: code=\(hotkey.keyCode), mods=\(hotkey.modifiers)")
}

Task { @MainActor in
    // Enable Hotkeys
    print("Attempting to register global hotkey...")
    HotkeyManager.shared.registerGlobalHotkey()
    print("Global hotkey registration called.")

    // Setup scanning schedule
    ServiceManager.shared.scheduleNextScan()
    print("Scan scheduled.")
}

// Listen for config changes from the main app
let center = DistributedNotificationCenter.default()
let observer = center.addObserver(forName: NSNotification.Name("com.businesstechdev.errthang.configChanged"), object: nil, queue: nil) { notification in
    print("Received config changed notification. Reloading...")
    Task { @MainActor in
        ConfigManager.shared.load()
        HotkeyManager.shared.registerGlobalHotkey()
        ServiceManager.shared.scheduleNextScan()
    }
}

// Keep the process alive
print("Entering run loop...")
app.run()

