import SwiftUI

@main
struct PandaPlayApp: App {
    init() {
        #if DEBUG
        // Keep a launch breadcrumb so a crash before the first SwiftUI render is
        // distinguishable from a crash inside the view hierarchy.
        let path = NSTemporaryDirectory() + "pandaplay-launch.txt"
        try? "app init \(Date())\n".write(toFile: path, atomically: true, encoding: .utf8)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
