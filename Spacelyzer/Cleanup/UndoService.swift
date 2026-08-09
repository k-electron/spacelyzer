import Foundation

/// Puts the most recent batch back where it came from (FR-059, FR-060).
///
/// Works from the path each item went into the Trash under, captured at removal time. Searching
/// the Trash by name at this point would be guesswork, because the system renames on collision and
/// the name that survived is not one that can be worked out afterwards (research R10).
nonisolated struct UndoService: Sendable {
    static let concurrency = 6

    private enum Outcome: Sendable {
        case restored(RestoredItem)
        case failed(UndoFailureRecord)
    }

    /// Asked before the action is offered, so nobody is invited to press something that cannot
    /// work.
    func availability(of items: [RemovedItem], disposition: Disposition) -> UndoAvailability {
        guard disposition == .trash else { return .unavailable(.wasPermanent) }
        guard !items.isEmpty else { return .unavailable(.trashEmptied) }

        let manager = FileManager.default
        let stillInTrash = items.filter { item in
            guard let trashPath = item.trashPath else { return false }
            return (try? manager.attributesOfItem(atPath: trashPath)) != nil
        }
        guard !stillInTrash.isEmpty else { return .unavailable(.trashEmptied) }

        // Offered when any of it can be put back, not only when all of it can. A partial
        // restoration is worth having, and the summary afterwards says exactly which items
        // returned rather than rounding up to success.
        let anySomewhereToGo = stillInTrash.contains { Self.parentExists(of: $0.originalPath) }
        guard anySomewhereToGo else { return .unavailable(.originalLocationMissing) }

        return .available
    }

    func undo(_ items: [RemovedItem]) -> AsyncStream<UndoEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(items, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ items: [RemovedItem],
        into continuation: AsyncStream<UndoEvent>.Continuation
    ) async {
        var restored: [RestoredItem] = []
        var failures: [UndoFailureRecord] = []

        await withTaskGroup(of: Outcome.self) { group in
            var pending = items.makeIterator()

            for _ in 0..<Self.concurrency {
                guard let item = pending.next() else { break }
                group.addTask { Self.restore(item) }
            }

            while let outcome = await group.next() {
                switch outcome {
                case let .restored(item):
                    restored.append(item)
                    continuation.yield(.restored(item))
                case let .failed(record):
                    failures.append(record)
                    continuation.yield(.failed(record))
                }
                if let item = pending.next() {
                    group.addTask { Self.restore(item) }
                }
            }
        }

        continuation.yield(.finished(UndoSummary(restored: restored, failures: failures)))
        continuation.finish()
    }

    private static func restore(_ item: RemovedItem) -> Outcome {
        func fail(_ reason: UndoBlocked) -> Outcome {
            .failed(UndoFailureRecord(path: item.originalPath, reason: reason))
        }

        guard let trashPath = item.trashPath else { return fail(.wasPermanent) }

        let manager = FileManager()
        guard (try? manager.attributesOfItem(atPath: trashPath)) != nil else {
            return fail(.trashEmptied)
        }
        guard parentExists(of: item.originalPath) else { return fail(.originalLocationMissing) }

        // Never over the top of something. Whatever is there now was put there after the removal,
        // and quietly replacing it would be a second deletion nobody asked for.
        guard (try? manager.attributesOfItem(atPath: item.originalPath)) == nil else {
            return fail(.somethingIsThereNow)
        }

        do {
            try manager.moveItem(
                at: URL(fileURLWithPath: trashPath),
                to: URL(fileURLWithPath: item.originalPath)
            )
            return .restored(RestoredItem(path: item.originalPath))
        } catch {
            return fail(.failed)
        }
    }

    private static func parentExists(of path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
