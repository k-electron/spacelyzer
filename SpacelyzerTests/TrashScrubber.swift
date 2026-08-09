import Foundation
@testable import Spacelyzer

/// Takes back out of the Trash whatever a test put there.
///
/// Removal tests move real files to the real Trash, because that is the thing being tested and
/// faking it would test the fake. What they must not do is leave a developer's Trash filling up
/// with fixtures across runs.
///
/// Only ever given paths a test received back from a removal it performed on a fixture of its own,
/// and it refuses anything that is not inside a Trash — so the worst a mistake here can do is
/// nothing at all.
struct TrashScrubber {
    private var paths: [String] = []

    mutating func track(_ summary: RemovalSummary) {
        paths.append(contentsOf: summary.removed.compactMap(\.trashPath))
    }

    mutating func track(_ path: String?) {
        guard let path else { return }
        paths.append(path)
    }

    /// Permanently removes the tracked items. Anything already restored is simply not there any
    /// more, which is not an error.
    func scrub() {
        for path in paths where Self.isInsideTrash(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// The one safety rule. A path that is not inside a Trash is not something this may touch,
    /// whatever a caller believes about it.
    static func isInsideTrash(_ path: String) -> Bool {
        path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}
