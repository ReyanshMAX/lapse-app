import Foundation

/// Append-only in-memory ring buffer, capped at 2000 lines. The only window
/// into capture behavior during the no-Mac / no-debugger period (D-024).
enum DebugLog {
    private static let lock = NSLock()
    private static var storage: [String] = []
    private static let capacity = 2000

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = formatter.string(from: Date())
        storage.append("[\(timestamp)] [\(category)] \(message)")
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Newest last, capped at 2000.
    static var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}
