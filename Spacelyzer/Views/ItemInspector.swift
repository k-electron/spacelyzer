import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Everything shown about one item (FR-048).
///
/// Assembled from what the scan already measured plus a single filesystem read, because the two
/// answer different questions. The scan knows what a folder occupies in total, which is expensive
/// to recompute and the reason anyone is looking. The filesystem knows the logical length, which is
/// not stored per node and is only worth reading for the one item being looked at.
nonisolated struct ItemDetails: Equatable, Sendable {
    let path: String
    let name: String
    let kind: NodeKind
    let category: FileCategory
    /// What the system calls this, as it appears in the file browser.
    let typeDescription: String
    /// Space occupied on disk. For a folder this is the whole subtree, as measured by the scan.
    let occupiedBytes: Int64
    /// Logical length, read at inspection time. Nil for a folder, which has no single length, and
    /// nil when the item can no longer be read.
    let logicalBytes: Int64?
    let created: Date
    let modified: Date
    let accessed: Date
    let itemCount: Int
    /// The same data is reachable under another name, and was counted there instead (FR-006).
    let countedElsewhere: Bool

    /// Whether both size figures need showing. A sparse or compressed file occupies less than it
    /// claims to contain, and hiding the difference makes the scanner look wrong.
    var sizesDiffer: Bool {
        guard let logicalBytes else { return false }
        return logicalBytes != occupiedBytes
    }
}

/// The outcome of asking whether an item can be previewed.
///
/// `unavailable` is an answer, not a failure. A folder has no preview and neither does an empty
/// file; saying so is the requirement, and an error or a blank panel is not (FR-050).
nonisolated enum PreviewState: Equatable, Sendable {
    case loading
    case ready(URL)
    case unavailable(reason: String)
}

/// What is known about the selected item, and the things that can be done to it from here.
///
/// Reading only. Nothing this type does alters the item's contents or where it lives (FR-049);
/// reveal and open hand the item to another process without touching it.
@MainActor
@Observable
final class ItemInspector {
    private(set) var details: ItemDetails?
    /// Nil when nothing is selected, which is a different thing from a selection with no preview.
    private(set) var preview: PreviewState?
    private(set) var url: URL?

    let activity = ActivityIndicator()

    private var work: Task<Void, Never>?
    private var inspectedPath: String?

    /// Looks at whatever is selected. The path is the same one both views already agree on, so the
    /// item is found by descending the measured tree rather than by scanning the disk again.
    func inspect(path: String, in root: ScannedItem, rootPath: String) {
        guard let item = Self.item(at: path, in: root, rootPath: rootPath) else {
            clear()
            return
        }

        work?.cancel()
        inspectedPath = path

        let target = URL(fileURLWithPath: path).standardizedFileURL
        url = target
        preview = .loading
        activity.begin("Looking at \(item.name)")

        work = Task {
            // Released on every path, including a superseded one, or the panel would report that
            // it is still working long after it stopped.
            defer { self.activity.end() }

            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolve(item: item, at: target, path: path)
            }.value

            // A selection that moved on while this was in flight discards the answer rather than
            // showing it against the wrong file.
            guard !Task.isCancelled, self.inspectedPath == path else { return }
            self.details = resolved.details
            self.preview = resolved.preview
        }
    }

    func clear() {
        work?.cancel()
        work = nil
        inspectedPath = nil
        details = nil
        preview = nil
        url = nil
        activity.end()
    }

    /// Opens the file browser with this item selected (FR-046).
    func reveal() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hands the item to whichever application claims it (FR-047).
    func open() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Reading

    private nonisolated static let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentAccessDateKey,
        .contentTypeKey,
        .localizedTypeDescriptionKey,
    ]

    /// One read answers both questions, so details never wait on the preview and the two can never
    /// disagree about the item they describe.
    nonisolated static func resolve(
        item: ScannedItem,
        at url: URL,
        path: String
    ) -> (details: ItemDetails, preview: PreviewState) {
        let values = try? url.resourceValues(forKeys: keys)

        let details = ItemDetails(
            path: path,
            name: item.name,
            kind: item.kind,
            category: item.category,
            typeDescription: describe(item: item, values: values),
            occupiedBytes: item.cumulativeSize,
            logicalBytes: values?.fileSize.map(Int64.init),
            created: item.created,
            modified: item.modified,
            accessed: item.accessed,
            itemCount: item.itemCount,
            countedElsewhere: item.countedElsewhere
        )

        return (details, availability(of: values, at: url))
    }

    /// Whether Quick Look has anything worth showing, decided before handing it the item.
    ///
    /// Quick Look answers almost anything with a generic icon, which looks like a preview and says
    /// nothing. Refusing the cases where that is all it would produce, and saying why, is more
    /// use than a picture of a folder.
    nonisolated static func availability(of values: URLResourceValues?, at url: URL) -> PreviewState {
        guard let values else {
            return .unavailable(reason: "This item is no longer at this location.")
        }
        if values.isSymbolicLink == true {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            return .unavailable(
                reason: destination.map { "This is a link to \($0). Its contents live there." }
                    ?? "This is a link to somewhere else. Its contents live there."
            )
        }
        if values.isDirectory == true, values.isPackage != true {
            return .unavailable(reason: "Folders have no preview. Select something inside one.")
        }
        if values.isReadable == false {
            return .unavailable(reason: "You do not have permission to read this item.")
        }
        if values.isDirectory != true, values.fileSize == 0 {
            return .unavailable(reason: "This file is empty.")
        }
        return .ready(url)
    }

    private nonisolated static func describe(item: ScannedItem, values: URLResourceValues?) -> String {
        if let described = values?.localizedTypeDescription, !described.isEmpty {
            return described
        }
        if let described = values?.contentType?.localizedDescription, !described.isEmpty {
            return described
        }
        switch item.kind {
        case .file: return "File"
        case .directory: return "Folder"
        case .package: return "Application"
        case .symlink: return "Alias"
        case .remainder: return "Several items"
        }
    }

    // MARK: - Finding

    /// Descends the measured tree to the item at this path.
    ///
    /// Paths are built the same way both views build them, by joining a parent to a child name, so
    /// the walk back down is the exact inverse. A volume root ends in a separator already, which is
    /// why the boundary is computed rather than assumed.
    nonisolated static func item(
        at path: String,
        in root: ScannedItem,
        rootPath: String
    ) -> ScannedItem? {
        if path == rootPath { return root }

        let boundary = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(boundary) else { return nil }

        var current = root
        for component in path.dropFirst(rootPath.count).split(separator: "/") {
            guard let next = current.children.first(where: { $0.name == component }) else {
                return nil
            }
            current = next
        }
        return current
    }
}
