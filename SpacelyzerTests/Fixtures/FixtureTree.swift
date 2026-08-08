import Foundation

/// Builds throwaway directory trees under the system temporary directory.
///
/// Every test runs against one of these. Nothing in the suite reads a real home directory or a
/// path hardcoded to a developer's machine, which Principle IV requires.
final class FixtureTree {
    let root: URL

    init(name: String = UUID().uuidString) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpacelyzerFixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file of exactly `bytes` length. Allocated size will be rounded up to a block
    /// boundary by the filesystem, which is what the scanner reports and what tests assert on.
    @discardableResult
    func file(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Writes a file with specific contents, for duplicate detection tests.
    @discardableResult
    func file(_ relativePath: String, contents: String) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A real application bundle, with the `Info.plist` the system needs before it will report the
    /// directory as a package.
    @discardableResult
    func appBundle(_ relativePath: String, binaryBytes: Int) throws -> URL {
        let bundle = try directory(relativePath)
        try directory("\(relativePath)/Contents/MacOS")
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>binary</string>
            <key>CFBundleIdentifier</key><string>test.fixture.bundle</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """
        try Data(plist.utf8).write(to: bundle.appending(path: "Contents/Info.plist"))
        try Data(repeating: 0x43, count: binaryBytes)
            .write(to: bundle.appending(path: "Contents/MacOS/binary"))
        return bundle
    }

    @discardableResult
    func hardLink(_ relativePath: String, to existing: URL) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: existing, to: url)
        return url
    }

    @discardableResult
    func symlink(_ relativePath: String, to destination: URL) throws -> URL {
        let url = root.appending(path: relativePath, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// Removes read and execute permission so traversal is denied, then restores it on teardown
    /// so the fixture can be cleaned up.
    @discardableResult
    func unreadableDirectory(_ relativePath: String) throws -> URL {
        let url = try directory(relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        unreadablePaths.append(url)
        return url
    }

    /// Generates a broad, shallow tree of roughly `fileCount` files, for performance runs.
    func generateTree(fileCount: Int, filesPerDirectory: Int = 100, bytesPerFile: Int = 1) throws {
        let directoryCount = max(1, fileCount / filesPerDirectory)
        for d in 0..<directoryCount {
            let dir = try directory("gen/d\(d)")
            for f in 0..<filesPerDirectory {
                let url = dir.appending(path: "f\(f)", directoryHint: .notDirectory)
                try Data(repeating: 0x42, count: bytesPerFile).write(to: url)
            }
        }
    }

    private var unreadablePaths: [URL] = []

    func restorePermissions() {
        for url in unreadablePaths {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        unreadablePaths.removeAll()
    }
}
