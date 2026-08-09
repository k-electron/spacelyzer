import Foundation

/// Carries out a plan, and nothing but a plan (FR-051 through FR-057).
///
/// There is no entry point taking raw paths. The only way to remove anything is to hand over a
/// `RemovalPlan`, and every item in one is checked against the guard a second time on its way out
/// — a plan is a value, and a value can be built by anyone, so the check that matters is the one
/// taken immediately before the item moves.
nonisolated struct RemovalService: Sendable {
    /// Enough to keep the disk busy without turning a mistake into a fast mistake. Trashing is a
    /// rename, so this is mostly waiting on metadata; past a handful of workers there is nothing
    /// further to win.
    static let concurrency = 6

    private let guardian: RemovalGuard

    init(guardian: RemovalGuard = RemovalGuard()) {
        self.guardian = guardian
    }

    private enum Outcome: Sendable {
        case removed(RemovedItem)
        case failed(RemovalFailureRecord)
    }

    func perform(_ plan: RemovalPlan, disposition: Disposition) -> AsyncStream<RemovalEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(plan, disposition: disposition, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ plan: RemovalPlan,
        disposition: Disposition,
        into continuation: AsyncStream<RemovalEvent>.Continuation
    ) async {
        var removed: [RemovedItem] = []
        var failures: [RemovalFailureRecord] = []
        var cancelled = false

        let guardian = guardian

        await withTaskGroup(of: Outcome.self) { group in
            var pending = plan.permitted.makeIterator()

            for _ in 0..<Self.concurrency {
                guard let item = pending.next() else { break }
                group.addTask { Self.remove(item, disposition: disposition, guardian: guardian) }
            }

            while let outcome = await group.next() {
                switch outcome {
                case let .removed(item):
                    removed.append(item)
                    continuation.yield(.removed(item))
                case let .failed(record):
                    failures.append(record)
                    continuation.yield(.failed(record))
                }

                // Cancelling stops the batch from starting anything further. What has already
                // moved stays moved — a half-finished removal is not rolled back, it is reported
                // (FR-056). Work already in flight is left to finish rather than abandoned
                // halfway, since a rename cannot be interrupted usefully anyway.
                if Task.isCancelled {
                    cancelled = true
                    continue
                }
                if let item = pending.next() {
                    group.addTask {
                        Self.remove(item, disposition: disposition, guardian: guardian)
                    }
                }
            }
        }

        // Always, including after cancellation, so nothing downstream has to guess whether a run
        // that stopped emitting is finished or merely quiet.
        continuation.yield(
            .finished(
                RemovalSummary(
                    disposition: disposition,
                    removed: removed,
                    failures: failures,
                    wasCancelled: cancelled
                )
            )
        )
        continuation.finish()
    }

    private static func remove(
        _ item: PlannedRemoval,
        disposition: Disposition,
        guardian: RemovalGuard
    ) -> Outcome {
        // The second look. Whatever was true when the plan was made, this is what is true now.
        if let refusal = guardian.refusal(for: item.url) {
            return .failed(
                RemovalFailureRecord(
                    path: item.url.path,
                    reason: refusal == .noLongerThere ? .noLongerThere : .failed
                )
            )
        }

        // One manager per removal. The shared instance is documented as safe across threads, but
        // this costs nothing and settles the question.
        let manager = FileManager()

        do {
            switch disposition {
            case .trash:
                var resulting: NSURL?
                try manager.trashItem(at: item.url, resultingItemURL: &resulting)
                // The path it went in under, which is the only handle that survives the system
                // renaming on collision, and so the only thing undo can work from (research R10).
                return .removed(
                    RemovedItem(
                        originalPath: item.url.path,
                        trashPath: (resulting as URL?)?.standardizedFileURL.path,
                        size: item.size
                    )
                )
            case .deletedPermanently:
                try manager.removeItem(at: item.url)
                return .removed(
                    RemovedItem(originalPath: item.url.path, trashPath: nil, size: item.size)
                )
            }
        } catch {
            return .failed(
                RemovalFailureRecord(path: item.url.path, reason: Self.reason(for: error))
            )
        }
    }

    private static func reason(for error: Error) -> RemovalFailure {
        guard let error = error as? CocoaError else { return .failed }
        switch error.code {
        case .fileNoSuchFile, .fileReadNoSuchFile: return .noLongerThere
        case .fileWriteNoPermission, .fileReadNoPermission: return .permissionDenied
        case .featureUnsupported, .fileWriteVolumeReadOnly: return .trashUnavailable
        default: return .failed
        }
    }
}
