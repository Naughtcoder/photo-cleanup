import SwiftUI
import BackgroundTasks
import UserNotifications
import Photos

let scanTaskID = "com.example.photocleanup.scan"

@main
struct PhotoCleanupApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: scanTaskID, using: nil) { task in
            Self.schedule()   // always queue the next run first
            let work = Task { @MainActor in
                let n = await Store.shared.scan()
                if n > 0 { await Self.notify(n) }
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(Store.shared)
        }
        .onChange(of: phase) { _, p in if p == .background { Self.schedule() } }
    }

    /// iOS picks the real run time. 5 hours is the earliest we ask for, aiming at roughly 3-4 runs a day.
    static func schedule() {
        let r = BGProcessingTaskRequest(identifier: scanTaskID)
        r.requiresExternalPower = false
        r.requiresNetworkConnectivity = false
        r.earliestBeginDate = Date().addingTimeInterval(5 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func notify(_ n: Int) async {
        let c = UNMutableNotificationContent()
        c.title = "Photo Cleanup"
        c.body = "\(n) photos ready to review"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
