import AppKit
import SwiftUI

/// Menu-bar-first application entry point.
///
/// `LSUIElement` is set in Info.plist, so there is no Dock icon by default: the app
/// lives in the menu bar and opens a dashboard window on demand.
@main
@MainActor
struct WiFiPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        AppDelegate.launchState = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarInterface(state: appState)
        } label: {
            MenuBarLabel(state: appState)
        }
        .menuBarExtraStyle(.window)

        Window("WiFiPilot", id: "dashboard") {
            DashboardInterface(state: appState)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsInterface(state: appState)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `WiFiPilotApp.init`, used to start monitoring as soon as the app launches
    /// rather than waiting for the menu bar panel to be opened.
    static weak var launchState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps get a menu bar item without a Dock icon or app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        if let state = Self.launchState {
            Task { await state.start() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
