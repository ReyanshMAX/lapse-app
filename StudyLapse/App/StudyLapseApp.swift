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
                .onOpenURL { url in
                    // Live Activity "Resume" deep link (docs/UI.md "Live
                    // Activity": "a Resume button backed by an App Intent
                    // that deep-links to Record — paused and ready"). No App
                    // Groups available (Q-004) to hand state across the
                    // process boundary any other way, so the URL itself is
                    // the entire signal.
                    guard url.host == "resume", coordinator.status == .paused else { return }
                    DebugLog.write("Session", "resume deep link received")
                    try? coordinator.resume()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            Task { await coordinator.handleScenePhase(phase) }
        }
    }
}
