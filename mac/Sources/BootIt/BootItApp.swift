import SwiftUI

struct BootItApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            // A single-window utility — drop the "New Window" menu item.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
