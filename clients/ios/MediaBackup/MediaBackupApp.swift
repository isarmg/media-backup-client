import BackgroundTasks
import SwiftUI

@main
struct MediaBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(BackupCoordinator.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: MobileContractV02.processingTask,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else { return }
            let work = Task {
                await BackupCoordinator.shared.runBackup(automatic: BackupCoordinator.shared.autoBackup)
                processing.setTaskCompleted(success: !Task.isCancelled)
            }
            processing.expirationHandler = {
                work.cancel()
                Task { @MainActor in BackupCoordinator.shared.stopTransfers() }
            }
        }
        return true
    }
}
