import SwiftData
import SwiftUI

@main
struct StudyLapseApp: App {
    private let container: ModelContainer
    @State private var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let values = try? StorageLocator.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        DebugLog.write("Storage", "root excluded from backup: \(values?.isExcludedFromBackup ?? false)")

        let container: ModelContainer
        do {
            container = try ModelContainerFactory.makeShared()
        } catch {
            DebugLog.write("Storage", "on-disk store failed to open (\(error)); falling back to in-memory")
            do {
                container = try ModelContainerFactory.makeInMemory()
            } catch {
                fatalError("Could not open any StudyLapse data store: \(error)")
            }
        }
        self.container = container
        _coordinator = State(initialValue: SessionCoordinator(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RecordView()
                .environment(coordinator)
                .task { await coordinator.recoverOnLaunch() }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            Task { await coordinator.handleScenePhase(phase) }
        }
    }
}
