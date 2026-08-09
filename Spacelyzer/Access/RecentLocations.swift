import Foundation
import SwiftData

/// Remembers where the user has scanned, so returning somewhere does not mean navigating to it
/// again (FR-009).
///
/// A bookmark is stored alongside the path. Access does not require one now that the app runs
/// unsandboxed, but a bookmark survives the folder being renamed or moved, which a path does not.
@MainActor
struct RecentLocations {
    let context: ModelContext

    /// Enough to be useful without turning the start pane into a history browser.
    static let limit = 8

    func all() -> [RecentLocation] {
        let descriptor = FetchDescriptor<RecentLocation>(
            sortBy: [SortDescriptor(\.lastScannedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func record(url: URL, measuredTotal: Int64) {
        let path = url.standardizedFileURL.path
        let existing = all().first { $0.displayPath == path }

        if let entry = existing {
            entry.lastScannedAt = .now
            entry.lastMeasuredTotal = measuredTotal
            entry.bookmark = try? url.bookmarkData()
        } else {
            context.insert(
                RecentLocation(
                    displayPath: path,
                    bookmark: try? url.bookmarkData(),
                    lastScannedAt: .now,
                    lastMeasuredTotal: measuredTotal
                )
            )
        }

        prune()
        try? context.save()
    }

    /// Prefers the bookmark, which tracks the folder if it moved, and falls back to the recorded
    /// path. Returns nil when the location is genuinely gone, so the caller can show it as
    /// unavailable rather than pretending it is empty.
    func resolve(_ entry: RecentLocation) -> URL? {
        if let bookmark = entry.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    entry.bookmark = try? url.bookmarkData()
                    entry.displayPath = url.standardizedFileURL.path
                    try? context.save()
                }
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        let url = URL(fileURLWithPath: entry.displayPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isAvailable(_ entry: RecentLocation) -> Bool {
        resolve(entry) != nil
    }

    func forget(_ entry: RecentLocation) {
        context.delete(entry)
        try? context.save()
    }

    private func prune() {
        let entries = all()
        guard entries.count > Self.limit else { return }
        for entry in entries.dropFirst(Self.limit) {
            context.delete(entry)
        }
    }
}
