import SwiftUI

@main
struct DocScanApp: App {
    @State private var session = ScanSession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(session)
        }
    }
}
