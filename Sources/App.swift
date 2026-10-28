import SwiftUI

@main
struct IPASignerApp: App {
    @StateObject private var model = AppModel()

    init() {
        Snapshot.parseArguments()
        if CLIMode.handleIfNeeded() { exit(0) }
    }

    var body: some Scene {
        WindowGroup("IPA 签名装机器") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
