import SwiftUI
import UIKit

@main
struct WipeWallApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var dashboard = DashboardModel()
    @StateObject private var voice = DonVoiceController()

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            WallCanvasView()
                .environmentObject(dashboard)
                .environmentObject(voice)
                .preferredColorScheme(.light)
                .statusBar(hidden: true)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    dashboard.start()
                    GoonLogClient.shared.start()
                }
                .task(id: scenePhase) {
                    if scenePhase == .active {
                        UIApplication.shared.isIdleTimerDisabled = true
                        voice.startWakeWordListening()
                        await dashboard.refresh()
                    } else {
                        // iOS 15 can preserve a dead Speech task across an interruption.
                        // Stop it explicitly so foregrounding always creates a fresh graph.
                        voice.pauseWakeWordListening()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await dashboard.refresh() }
                }
        }
    }
}
