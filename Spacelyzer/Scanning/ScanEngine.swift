import Foundation
import UniformTypeIdentifiers

/// A measured item, as a value type. The scan produces these off the main actor; they are turned
/// into `ScanNode` models afterwards, so no model object ever crosses an actor boundary.
nonisolated struct ScannedItem: Sendable {
    var name: String
    var kind: NodeKind
    var category: FileCategory
    var ownSize: Int64
    var cumulativeSize: Int64
    var itemCount: Int
    var created: Date
    var modified: Date
    var accessed: Date
    var countedElsewhere: Bool
    var unreadable: Bool
    var hasUnexpandedContents: Bool
    var children: [ScannedItem]
}

nonisolated struct ScanTotals: Sendable {
    var measuredBytes: Int64 = 0
    var itemsSeen: Int = 0
}

nonisolated enum ScanEvent: Sendable {
    case progress(totals: ScanTotals, currentPath: String)
    case skipped(path: String, reason: SkipReason)
    case completed(root: ScannedItem, totals: ScanTotals)
    case cancelled(root: ScannedItem, totals: ScanTotals)
}

nonisolated struct ScanOptions: Sendable {
    /// Bundles are measured whole but not enumerated, so an installed app arrives as one item
    /// (FR-022). Opening one triggers a separate targeted pass.
    var treatPackagesAsItems: Bool = true
    /// Standardized paths. Set through `exclude(_:)` so callers cannot accidentally store an
    /// unnormalised spelling that silently never matches.
    private(set) var excludedPaths: Set<String> = []
    var progressInterval: Duration = .milliseconds(100)

    mutating func exclude(_ urls: [URL]) {
        for url in urls {
            excludedPaths.insert(url.standardizedFileURL.path)
        }
    }
}

/// Traversal, byte accounting, progress, and cancellation.
///
/// Everything here runs off the main actor. Progress is coalesced rather than emitted per file:
/// a million individual updates would freeze the very interface meant to display them.
nonisolated struct ScanEngine: Sendable {
    let fileSystem: FileSystemProvider

    init(fileSystem: FileSystemProvider = LiveFileSystem()) {
        self.fileSystem = fileSystem
    }

    func scan(root: URL, options: ScanOptions = ScanOptions()) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var context = Context(options: options, fileSystem: fileSystem, continuation: continuation)
                let rootItem = await context.walk(url: root, isRoot: true)
                let event: ScanEvent = Task.isCancelled
                    ? .cancelled(root: rootItem, totals: context.totals)
                    : .completed(root: rootItem, totals: context.totals)
                continuation.yield(event)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Measures the contents of one bundle on demand, when the user asks to look inside it.
    func expandPackage(at url: URL, options: ScanOptions = ScanOptions()) async -> ScannedItem {
        var opened = options
        opened.treatPackagesAsItems = false
        var context = Context(options: opened, fileSystem: fileSystem, continuation: nil)
        return await context.walk(url: url, isRoot: true, forceDescend: true)
    }
}

private nonisolated struct Context {
    let options: ScanOptions
    let fileSystem: FileSystemProvider
    let continuation: AsyncStream<ScanEvent>.Continuation?

    var totals = ScanTotals()
    /// Only holds identities for entries reporting more than one link, so its size tracks a rare
    /// case rather than the whole scan.
    var seenIdentities: Set<FileIdentity> = []
    var lastProgress: ContinuousClock.Instant = .now
    let clock = ContinuousClock()

    init(options: ScanOptions, fileSystem: FileSystemProvider, continuation: AsyncStream<ScanEvent>.Continuation?) {
        self.options = options
        self.fileSystem = fileSystem
        self.continuation = continuation
    }

    mutating func walk(url: URL, isRoot: Bool = false, forceDescend: Bool = false) async -> ScannedItem {
        let name = isRoot ? url.path : url.lastPathComponent

        guard let selfEntry = describe(url: url, name: name) else {
            return ScannedItem(
                name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
                itemCount: 1, created: .distantPast, modified: .distantPast, accessed: .distantPast,
                countedElsewhere: false, unreadable: true, hasUnexpandedContents: false, children: []
            )
        }

        let isPackageHeldWhole = selfEntry.isPackage && options.treatPackagesAsItems && !forceDescend
        guard selfEntry.isDirectory, !isPackageHeldWhole else {
            return leaf(from: selfEntry, kindOverride: isPackageHeldWhole ? .package : nil)
        }

        // Compared on standardized paths, because a URL built by appending and one produced by
        // enumeration can spell the same location differently.
        if options.excludedPaths.contains(url.standardizedFileURL.path) {
            report(skipped: url.path, reason: .userExcluded)
            return ScannedItem(
                name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
                itemCount: 1, created: selfEntry.created, modified: selfEntry.modified,
                accessed: selfEntry.accessed, countedElsewhere: false, unreadable: false,
                hasUnexpandedContents: false, children: []
            )
        }

        var entries: [FileEntry] = []
        do {
            entries = try fileSystem.contents(of: url)
        } catch let FileSystemError.unreadable(_, reason) {
            report(skipped: url.path, reason: reason)
            return ScannedItem(
                name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
                itemCount: 1, created: selfEntry.created, modified: selfEntry.modified,
                accessed: selfEntry.accessed, countedElsewhere: false, unreadable: true,
                hasUnexpandedContents: false, children: []
            )
        } catch {
            report(skipped: url.path, reason: .unreadable)
            return ScannedItem(
                name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
                itemCount: 1, created: selfEntry.created, modified: selfEntry.modified,
                accessed: selfEntry.accessed, countedElsewhere: false, unreadable: true,
                hasUnexpandedContents: false, children: []
            )
        }

        var children: [ScannedItem] = []
        children.reserveCapacity(entries.count)

        for entry in entries {
            // Cancellation is checked at every directory boundary, which bounds the worst case to
            // one directory's enumeration and satisfies FR-004's one second.
            if Task.isCancelled { break }

            let heldWhole = entry.isDirectory && entry.isPackage && options.treatPackagesAsItems
            if entry.isDirectory, !heldWhole {
                children.append(await walk(url: entry.url))
            } else {
                // A bundle becomes a single measured item rather than an expanded folder, so it
                // needs the package kind here as well as on the root path through `walk`.
                children.append(leaf(from: entry, kindOverride: heldWhole ? .package : nil))
            }
        }

        var item = ScannedItem(
            name: name,
            kind: .directory,
            category: .folder,
            ownSize: 0,
            cumulativeSize: 0,
            itemCount: 1,
            created: selfEntry.created,
            modified: selfEntry.modified,
            accessed: selfEntry.accessed,
            countedElsewhere: false,
            unreadable: false,
            hasUnexpandedContents: false,
            children: children
        )
        // A folder reports both its own contents and everything beneath it (FR-008).
        item.cumulativeSize = children.reduce(0) { $0 + $1.cumulativeSize }
        item.itemCount = children.reduce(1) { $0 + $1.itemCount }
        emitProgressIfDue(path: url.path)
        return item
    }

    private mutating func leaf(from entry: FileEntry, kindOverride: NodeKind? = nil) -> ScannedItem {
        var counted = true

        if entry.linkCount > 1, let identity = fileSystem.identity(of: entry.url) {
            // Already-counted data still appears at this path, but contributes nothing further.
            counted = seenIdentities.insert(identity).inserted
        }

        let kind: NodeKind = kindOverride ?? (entry.isSymlink ? .symlink : (entry.isDirectory ? .directory : .file))
        // A symlink is recorded but never followed, so it cannot loop or double count (FR-007).
        let size = (counted && !entry.isSymlink) ? entry.allocatedSize : 0

        totals.measuredBytes += size
        totals.itemsSeen += 1

        var packageSize = size
        if kindOverride == .package {
            packageSize = counted ? directorySize(of: entry.url) : 0
            totals.measuredBytes += packageSize - size
        }

        return ScannedItem(
            name: entry.name,
            kind: kind,
            category: FileCategory.classify(entry.contentType, isDirectory: entry.isDirectory),
            ownSize: packageSize,
            cumulativeSize: packageSize,
            itemCount: 1,
            created: entry.created,
            modified: entry.modified,
            accessed: entry.accessed,
            countedElsewhere: !counted,
            unreadable: false,
            hasUnexpandedContents: kindOverride == .package,
            children: []
        )
    }

    /// Total allocated size of a bundle, measured without building nodes for its contents.
    private func directorySize(of url: URL) -> Int64 {
        guard let entries = try? fileSystem.contents(of: url) else { return 0 }
        return entries.reduce(Int64(0)) { total, entry in
            if entry.isDirectory && !entry.isSymlink {
                return total + directorySize(of: entry.url)
            }
            return total + (entry.isSymlink ? 0 : entry.allocatedSize)
        }
    }

    private func describe(url: URL, name: String) -> FileEntry? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .linkCountKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            .contentTypeKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isSymlink = values.isSymbolicLink ?? false
        let isDirectory = (values.isDirectory ?? false) && !isSymlink
        return FileEntry(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: LiveFileSystem.isPackage(values: values, isDirectory: isDirectory),
            isSymlink: isSymlink,
            allocatedSize: Int64(values.totalFileAllocatedSize ?? 0),
            linkCount: values.linkCount ?? 1,
            created: values.creationDate ?? .distantPast,
            modified: values.contentModificationDate ?? .distantPast,
            accessed: values.contentAccessDate ?? .distantPast,
            contentType: values.contentType
        )
    }

    private func report(skipped path: String, reason: SkipReason) {
        continuation?.yield(.skipped(path: path, reason: reason))
    }

    private mutating func emitProgressIfDue(path: String) {
        guard let continuation else { return }
        let now = clock.now
        guard now - lastProgress >= options.progressInterval else { return }
        lastProgress = now
        continuation.yield(.progress(totals: totals, currentPath: path))
    }
}
