import SwiftUI

@main
struct StudyLapseApp: App {
    init() {
        let values = try? StorageLocator.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        DebugLog.write("Storage", "root excluded from backup: \(values?.isExcludedFromBackup ?? false)")
    }

    var body: some Scene {
        WindowGroup {
            RecordView()
        }
    }
}
