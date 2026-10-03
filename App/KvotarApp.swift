import SwiftUI

@main
struct KvotarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar-only app (LSUIElement). The status item and popover are owned by AppDelegate;
        // this empty Settings scene just satisfies the App protocol.
        Settings {
            EmptyView()
        }
    }
}
