import Foundation

/// Source-contract tests locate the project, not a fixed number of parents.
/// Test files may move between domains without silently dropping product paths.
enum ProductSourceFiles {
    static func iosRoot(file: String = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Floweroll/App").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func ordinaryTaskSources() throws -> [URL] {
        let app = try iosRoot().appendingPathComponent("Floweroll/App")
        var paths = ["FlowerollIntents.swift", "ContentView.swift", "RuntimeClient/RuntimeTaskStore.swift"]
            .map { app.appendingPathComponent($0) }
        let directories = ["Shell", "Home", "Tasks", "Settings", "Developer", "RuntimeClient/Presentation"]
        for directory in directories {
            let root = app.appendingPathComponent(directory)
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let sources = entries.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            guard !sources.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            paths += sources
        }
        return paths.sorted { $0.path < $1.path }
    }
}
