import Foundation

/// Single place that resolves the on-disk root for session media. Only
/// relative paths are ever persisted (D-021); resolve through here.
enum StorageLocator {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var root = base.appendingPathComponent("StudyLapse", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }()

    static func url(forRelativePath relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func relativePath(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
