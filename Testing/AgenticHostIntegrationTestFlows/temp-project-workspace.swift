import Foundation

struct TempProjectWorkspace: Sendable {
    let root: URL

    init(
        _ name: String
    ) throws {
        let safeName = name
            .replacingOccurrences(
                of: "/",
                with: "-"
            )
            .replacingOccurrences(
                of: " ",
                with: "-"
            )

        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentic-interface-testflows",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(safeName)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            .standardizedFileURL

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    init(
        root: URL,
        clean: Bool = true
    ) throws {
        self.root = root.standardizedFileURL

        if clean,
           FileManager.default.fileExists(
               atPath: self.root.path
           ) {
            try FileManager.default.removeItem(
                at: self.root
            )
        }

        try FileManager.default.createDirectory(
            at: self.root,
            withIntermediateDirectories: true
        )
    }

    func file(
        _ path: String
    ) -> URL {
        root.appendingPathComponent(
            path,
            isDirectory: false
        )
    }

    func write(
        _ content: String,
        to path: String
    ) throws {
        let url = file(
            path
        )

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try content.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    func read(
        _ path: String
    ) throws -> String {
        try String(
            contentsOf: file(
                path
            ),
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(
            at: root
        )
    }
}
