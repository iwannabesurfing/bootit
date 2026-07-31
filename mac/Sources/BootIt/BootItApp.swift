import SwiftUI

struct BootItApp: App {
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
                if let repository = Self.repository {
                    Link("BootIt on GitHub", destination: repository)
                }
                if let issues = Self.issues {
                    Link("Report an Issue", destination: issues)
                }
            }
        }
    }
}
