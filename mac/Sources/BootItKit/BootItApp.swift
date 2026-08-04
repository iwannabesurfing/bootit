import AppKit
import SwiftUI

/// Closing the window quits.
///
/// BootIt removes the New Window command, so without this, closing the last
/// window leaves a running app with no way to get a window back — visible in the
/// Dock and the ⌘-Tab switcher, doing nothing. That was the reason the final
/// step had to offer "Quit" as its primary button; with this in place, the
/// button can be the thing the user actually wants next.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Every run leaves a copy trace in `~/Library/Logs/BootIt/`, so something
    /// has to clear the old ones out. At launch and off the main thread: a
    /// folder scan is cheap, but nothing about it needs to happen before the
    /// window appears.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { CopyTraceWriter.pruneOldTraces() }
    }
}

struct BootItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    static let repository = URL(string: "https://github.com/iwannabesurfing/bootit")
    static let issues = URL(string: "https://github.com/iwannabesurfing/bootit/issues")

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 680, idealWidth: 760, minHeight: 540, idealHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            // A single-window utility — drop the "New Window" menu item.
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .help) {
                // A root daemon the user cannot see or remove from the app that
                // installed it would be indefensible; this is that door.
                Button("Privileged Helper…") { openHelperWindow() }
                Divider()
                if let repository = Self.repository {
                    Link("BootIt on GitHub", destination: repository)
                }
                if let issues = Self.issues {
                    Link("Report an Issue", destination: issues)
                }
            }
        }

        Window("Privileged Helper", id: Self.helperWindowID) {
            HelperStatusView()
        }
        .windowResizability(.contentSize)
    }

    static let helperWindowID = "helper-status"

    @Environment(\.openWindow) private var openWindow
    private func openHelperWindow() { openWindow(id: Self.helperWindowID) }
}
