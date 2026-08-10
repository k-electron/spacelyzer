import Foundation

/// One file among several with identical contents.
nonisolated struct DuplicateCopy: Sendable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    /// Space on disk. Every copy in a set has the same, since identical contents of equal
    /// allocated size is what put them together.
    let size: Int64

    var name: String { (path as NSString).lastPathComponent }
    var enclosingFolder: String { (path as NSString).deletingLastPathComponent }
}

/// Files whose contents are byte for byte the same (FR-062).
///
/// The set owns which of its copies are marked to go, and refuses to mark the last one. FR-065
/// asks that no action be able to remove every copy, and a view that merely disables a button is
/// one refactor away from not enforcing anything — so the rule lives here, where the only way to
/// express a removal is to ask this type for one.
nonisolated struct DuplicateSet: Sendable, Identifiable, Equatable {
    /// The content digest the copies share. Stable across runs, so a set keeps its identity while
    /// the view is open.
    let id: String
    /// Ordered by path, so a set presents its copies the same way twice.
    let copies: [DuplicateCopy]

    private(set) var marked: Set<String> = []

    init(id: String, copies: [DuplicateCopy]) {
        self.id = id
        self.copies = copies.sorted { $0.path < $1.path }
    }

    /// What one copy occupies. All of them occupy the same.
    var copySize: Int64 { copies.first?.size ?? 0 }

    /// What could be reclaimed by keeping one copy and removing the rest (FR-064).
    var recoverableSize: Int64 { copySize * Int64(max(0, copies.count - 1)) }

    /// What the current marks would reclaim.
    var markedSize: Int64 { copySize * Int64(marked.count) }

    /// How many copies may be marked in total. One fewer than there are.
    var markableCount: Int { max(0, copies.count - 1) }

    func isMarked(_ path: String) -> Bool { marked.contains(path) }

    /// Nil when this copy may be marked, and the reason when it may not.
    func refusal(forMarking path: String) -> KeepOneRefusal? {
        guard copies.contains(where: { $0.path == path }) else { return .notInThisSet }
        if marked.contains(path) { return nil }
        guard marked.count < markableCount else { return .wouldLeaveNoCopy }
        return nil
    }

    /// Marks a copy to be removed, or refuses. Returns whether the set changed, so a view can tell
    /// a refusal from a no-op without asking twice.
    @discardableResult
    mutating func mark(_ path: String) -> Bool {
        guard refusal(forMarking: path) == nil, !marked.contains(path) else { return false }
        marked.insert(path)
        return true
    }

    @discardableResult
    mutating func unmark(_ path: String) -> Bool {
        marked.remove(path) != nil
    }

    mutating func unmarkAll() {
        marked.removeAll()
    }

    /// Marks every copy but the first, which is the common thing to want and the one place it
    /// would be tempting to write `copies.forEach(mark)` and quietly remove everything.
    mutating func markAllButOne() {
        marked = Set(copies.dropFirst().map(\.path))
    }

    /// The marked copies, as something the removal machinery will accept.
    ///
    /// Built from `marked`, which cannot hold every copy, so no plan produced here can empty a
    /// set however it is called.
    func removalCandidates() -> [RemovalCandidate] {
        copies
            .filter { marked.contains($0.path) }
            .map { RemovalCandidate(url: URL(fileURLWithPath: $0.path), size: $0.size) }
    }

    /// The same set with the given copies gone, or nil when fewer than two remain — at which point
    /// it is not a duplicate set any more and should stop being shown as one.
    func removing(_ paths: Set<String>) -> DuplicateSet? {
        let left = copies.filter { !paths.contains($0.path) }
        guard left.count > 1 else { return nil }
        var next = DuplicateSet(id: id, copies: left)
        next.marked = marked.subtracting(paths)
        return next
    }
}

nonisolated enum KeepOneRefusal: Equatable, Sendable {
    case wouldLeaveNoCopy
    case notInThisSet

    var explanation: String {
        switch self {
        case .wouldLeaveNoCopy:
            "One copy has to stay. Removing this one as well would delete the file rather than "
                + "its duplicates."
        case .notInThisSet:
            "That file is not one of these copies."
        }
    }
}
