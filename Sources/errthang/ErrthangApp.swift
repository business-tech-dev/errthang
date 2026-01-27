import SwiftUI
import ErrthangCore
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        // Enforce single instance
        if let bundleId = Bundle.main.bundleIdentifier {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            let currentApp = NSRunningApplication.current

            for app in runningApps {
                // Ignore the current app instance
                if app == currentApp { continue }

                // Ignore the background service
                if let execURL = app.executableURL, execURL.lastPathComponent == "errthang-service" {
                    continue
                }

                print("Another instance is running. Activating it and terminating this one.")
                app.activate(options: [.activateAllWindows])
                NSApplication.shared.terminate(nil)
                return
            }
        }

        NSRunningApplication.current.activate(options: .activateAllWindows)
        NSApplication.shared.windows.forEach { $0.makeKeyAndOrderFront(nil) }

        // Initialize ServiceManager (Background Tasks)
        ServiceManager.shared.setup()

        // Start loading search index
        Task {
            await SearchService.shared.loadIndex()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("Application terminating, saving index...")
        Task {
            await SearchService.shared.saveIndex()
        }
    }
}

@main
struct ErrthangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var persistenceController = PersistenceController.shared
    @StateObject private var configManager = ConfigManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(configManager.config.appearance.colorScheme)
                .id(configManager.config.appearance) // Force recreation on change to ensure theme applies
                .onAppear {
                    NSRunningApplication.current.activate(options: .activateAllWindows)
                }
        }
        .commands {
        }

        Settings {
            SettingsView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(configManager.config.appearance.colorScheme)
                .id(configManager.config.appearance)
        }
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
