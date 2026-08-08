import Foundation
import UniformTypeIdentifiers

/// Uniquely identifies stored data, so the same bytes reachable through several names are counted
/// once (FR-006).
nonisolated struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

nonisolated struct FileEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    /// Space occupied on disk, not logical length.
    let allocatedSize: Int64
    let linkCount: Int
    let created: Date
    let modified: Date
    let accessed: Date
    let contentType: UTType?
}

nonisolated enum FileSystemError: Error {
    case unreadable(URL, reason: SkipReason)
}

/// The seam that lets traversal be tested against constructed fixture trees. Tests point it at a
/// temporary directory; nothing in the suite reads a real home directory (Principle IV).
nonisolated protocol FileSystemProvider: Sendable {
    func contents(of directory: URL) throws -> [FileEntry]
    func identity(of url: URL) -> FileIdentity?
    /// The root of the volume containing this item, used to recognise a separate mount.
    func volumeRoot(of url: URL) -> URL?
}

nonisolated struct LiveFileSystem: FileSystemProvider {
    private static let keys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .linkCountKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentAccessDateKey,
        .contentTypeKey,
    ]

    func contents(of directory: URL) throws -> [FileEntry] {
        let manager = FileManager.default
        let urls: [URL]
        do {
            // Resource values are prefetched in the same call. Requesting them afterwards would
            // reintroduce a per-file round trip into the kernel, which is the cost the bulk
            // interface exists to avoid (research R2).
            urls = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Self.keys,
                options: [.skipsSubdirectoryDescendants]
            )
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw FileSystemError.unreadable(directory, reason: .permissionDenied)
        } catch {
            throw FileSystemError.unreadable(directory, reason: .unreadable)
        }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
            let isSymlink = values.isSymbolicLink ?? false
            let isDirectory = (values.isDirectory ?? false) && !isSymlink
            let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            return FileEntry(
                url: url,
                name: values.name ?? url.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: Self.isPackage(values: values, isDirectory: isDirectory),
                isSymlink: isSymlink,
                allocatedSize: Int64(allocated),
                linkCount: values.linkCount ?? 1,
                created: values.creationDate ?? .distantPast,
                modified: values.contentModificationDate ?? .distantPast,
                accessed: values.contentAccessDate ?? .distantPast,
                contentType: values.contentType
            )
        }
    }

    /// `isPackage` alone is unreliable for directories the system has not been asked about, so
    /// the declared content type is consulted as well.
    static func isPackage(values: URLResourceValues, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }
        if values.isPackage == true { return true }
        guard let type = values.contentType else { return false }
        return type.conforms(to: .package) || type.conforms(to: .bundle)
    }

    func volumeRoot(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    /// Only consulted for entries reporting more than one link, so its per-file cost is paid on a
    /// rare case rather than on every file in the scan.
    func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
