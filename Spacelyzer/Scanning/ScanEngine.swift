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
/// Claims stored data the first time it is seen, so bytes reachable through several hard links
/// are counted once even when the subtrees holding them are walked concurrently (FR-006).
///
/// Only consulted for entries reporting more than one link, which is rare, so the cost of the
/// actor hop is paid on the exception rather than on every file.
/// Hands out permission to walk a subtree concurrently.
///
/// A caller that cannot get a slot walks the subtree inline instead of waiting. Nothing ever
/// blocks on a permit, so a deep tree cannot deadlock itself by holding slots while its children
/// ask for more.
actor ConcurrencyGate {
    private var inFlight = 0
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func tryAcquire() -> Bool {
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    func release() { inFlight = max(0, inFlight - 1) }
}

actor IdentityRegistry {
    private var seen: Set<FileIdentity> = []

    func claim(_ identity: FileIdentity) -> Bool {
        seen.insert(identity).inserted
    }
}

/// Accumulates progress from every concurrent walker.
///
/// Updates are deliberately lossy: the stream buffers only the newest value, so when walkers
/// outpace the interface the intermediate counts are dropped rather than queued. A backlog of
/// stale progress helps nobody and costs everybody.
actor ProgressAccumulator {
    private var totals = ScanTotals()
    private var lastEmit: ContinuousClock.Instant = .now
    private let clock = ContinuousClock()
    private let interval: Duration
    private let continuation: AsyncStream<ScanEvent>.Continuation?

    init(interval: Duration, continuation: AsyncStream<ScanEvent>.Continuation?) {
        self.interval = interval
        self.continuation = continuation
    }

    func add(bytes: Int64, items: Int, path: String) {
        totals.measuredBytes += bytes
        totals.itemsSeen += items
        let now = clock.now
        guard now - lastEmit >= interval else { return }
        lastEmit = now
        continuation?.yield(.progress(totals: totals, currentPath: path))
    }

    func snapshot() -> ScanTotals { totals }
}

nonisolated struct ScanEngine: Sendable {
    let fileSystem: FileSystemProvider
    /// Bounds how many directories are walked at once. Unbounded fan-out thrashes on I/O-bound
    /// work rather than going faster.
    let maxConcurrency: Int

    init(
        fileSystem: FileSystemProvider = LiveFileSystem(),
        maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.fileSystem = fileSystem
        self.maxConcurrency = maxConcurrency
    }

    func scan(root: URL, options: ScanOptions = ScanOptions()) -> AsyncStream<ScanEvent> {
        // Only the newest progress value is kept. Dropping intermediate updates is the point:
        // the interface only ever needs the latest number.
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let registry = IdentityRegistry()
                let progress = ProgressAccumulator(
                    interval: options.progressInterval,
                    continuation: continuation
                )
                let walker = Walker(
                    options: options,
                    fileSystem: fileSystem,
                    continuation: continuation,
                    registry: registry,
                    progress: progress,
                    gate: ConcurrencyGate(limit: maxConcurrency)
                )
                let rootItem = await walker.walk(url: root, isRoot: true)
                let totals = await progress.snapshot()
                let event: ScanEvent = Task.isCancelled
                    ? .cancelled(root: rootItem, totals: totals)
                    : .completed(root: rootItem, totals: totals)
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
        let walker = Walker(
            options: opened,
            fileSystem: fileSystem,
            continuation: nil,
            registry: IdentityRegistry(),
            progress: ProgressAccumulator(interval: .seconds(3600), continuation: nil),
            gate: ConcurrencyGate(limit: maxConcurrency)
        )
        return await walker.walk(url: url, isRoot: true, forceDescend: true)
    }
}

private nonisolated struct Walker: Sendable {
    let options: ScanOptions
    let fileSystem: FileSystemProvider
    let continuation: AsyncStream<ScanEvent>.Continuation?
    let registry: IdentityRegistry
    let progress: ProgressAccumulator
    let gate: ConcurrencyGate

    func walk(url: URL, isRoot: Bool = false, forceDescend: Bool = false) async -> ScannedItem {
        await walkDirectory(url: url, isRoot: isRoot, forceDescend: forceDescend)
    }

    /// Every directory may fan its subdirectories out concurrently, subject to the gate. A
    /// subtree that cannot get a slot is walked inline, so parallelism follows wherever the tree
    /// is actually wide instead of depending on its shape at the root.
    private func walkDirectory(url: URL, isRoot: Bool = false, forceDescend: Bool = false) async -> ScannedItem {
        let name = isRoot ? url.path : url.lastPathComponent

        guard let selfEntry = describe(url: url, name: name) else {
            return unreadableFolder(named: name)
        }

        let heldWhole = selfEntry.isPackage && options.treatPackagesAsItems && !forceDescend
        guard selfEntry.isDirectory, !heldWhole else {
            return await leaf(from: selfEntry, kindOverride: heldWhole ? .package : nil)
        }

        // Compared on standardized paths, because a URL built by appending and one produced by
        // enumeration can spell the same location differently.
        if options.excludedPaths.contains(url.standardizedFileURL.path) {
            report(skipped: url.path, reason: .userExcluded)
            return emptyFolder(named: name, from: selfEntry)
        }

        let entries: [FileEntry]
        do {
            entries = try readEntries(of: url)
        } catch let FileSystemError.unreadable(_, reason) {
            report(skipped: url.path, reason: reason)
            return unreadableFolder(named: name, from: selfEntry)
        } catch {
            report(skipped: url.path, reason: .unreadable)
            return unreadableFolder(named: name, from: selfEntry)
        }

        var ordered = [ScannedItem?](repeating: nil, count: entries.count)

        await withTaskGroup(of: (Int, ScannedItem).self) { group in
            var spawned = 0

            for (index, entry) in entries.enumerated() {
                // Cancellation is checked at every directory boundary, which bounds the worst
                // case to one directory's enumeration and satisfies FR-004's one second.
                if Task.isCancelled { break }

                let heldWhole = entry.isDirectory && entry.isPackage && options.treatPackagesAsItems
                guard entry.isDirectory, !heldWhole else {
                    ordered[index] = await leaf(from: entry, kindOverride: heldWhole ? .package : nil)
                    continue
                }

                if await gate.tryAcquire() {
                    let target = entry.url
                    group.addTask {
                        let item = await walkDirectory(url: target)
                        await gate.release()
                        return (index, item)
                    }
                    spawned += 1
                } else {
                    ordered[index] = await walkDirectory(url: entry.url)
                }
            }

            for await (index, item) in group {
                ordered[index] = item
                _ = spawned
            }
        }

        // Restored to enumeration order so results do not depend on completion order.
        let children = ordered.compactMap { $0 }
        await progress.add(bytes: 0, items: 0, path: url.path)
        return folder(named: name, from: selfEntry, children: children)
    }

    private func readEntries(of url: URL) throws -> [FileEntry] {
        try fileSystem.contents(of: url)
    }

    private func leaf(from entry: FileEntry, kindOverride: NodeKind? = nil) async -> ScannedItem {
        var counted = true

        if entry.linkCount > 1, let identity = fileSystem.identity(of: entry.url) {
            // Already-counted data still appears at this path, but contributes nothing further.
            counted = await registry.claim(identity)
        }

        let kind: NodeKind = kindOverride
            ?? (entry.isSymlink ? .symlink : (entry.isDirectory ? .directory : .file))
        // A symlink is recorded but never followed, so it cannot loop or double count (FR-007).
        var size = (counted && !entry.isSymlink) ? entry.allocatedSize : 0
        if kindOverride == .package {
            size = counted ? directorySize(of: entry.url) : 0
        }

        await progress.add(bytes: size, items: 1, path: entry.url.path)

        return ScannedItem(
            name: entry.name,
            kind: kind,
            category: FileCategory.classify(entry.contentType, isDirectory: entry.isDirectory),
            ownSize: size,
            cumulativeSize: size,
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

    private func folder(named name: String, from entry: FileEntry, children: [ScannedItem]) -> ScannedItem {
        var item = emptyFolder(named: name, from: entry)
        item.children = children
        // A folder reports both its own contents and everything beneath it (FR-008).
        item.cumulativeSize = children.reduce(0) { $0 + $1.cumulativeSize }
        item.itemCount = children.reduce(1) { $0 + $1.itemCount }
        return item
    }

    private func emptyFolder(named name: String, from entry: FileEntry) -> ScannedItem {
        ScannedItem(
            name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
            itemCount: 1, created: entry.created, modified: entry.modified, accessed: entry.accessed,
            countedElsewhere: false, unreadable: false, hasUnexpandedContents: false, children: []
        )
    }

    private func unreadableFolder(named name: String, from entry: FileEntry? = nil) -> ScannedItem {
        ScannedItem(
            name: name, kind: .directory, category: .folder, ownSize: 0, cumulativeSize: 0,
            itemCount: 1, created: entry?.created ?? .distantPast,
            modified: entry?.modified ?? .distantPast, accessed: entry?.accessed ?? .distantPast,
            countedElsewhere: false, unreadable: true, hasUnexpandedContents: false, children: []
        )
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
}
