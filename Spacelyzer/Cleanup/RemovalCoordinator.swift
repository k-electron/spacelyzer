import Foundation
import Observation

/// Runs the removal flow: work out what would happen, ask, do it, say what happened.
///
/// Holds no store and writes no history. What actually happened leaves here as a value, and the
/// window records it — which keeps the one destructive path in the app free of any dependency on
/// where records are kept.
@MainActor
@Observable
final class RemovalCoordinator {
    /// Non-nil while the confirmation is up. Worked out before it appears, so refusals are
    /// something the user reads while deciding rather than discovers afterwards (FR-055).
    private(set) var plan: RemovalPlan?
    /// Set when the user has asked for permanent deletion within the confirmation (FR-054).
    var deletePermanently = false

    private(set) var isRemoving = false
    private(set) var removedCount = 0
    private(set) var plannedCount = 0

    /// Non-nil once a batch has finished, until dismissed.
    private(set) var summary: RemovalSummary?
    private(set) var undoAvailability: UndoAvailability = .unavailable(.trashEmptied)
    private(set) var isUndoing = false
    private(set) var undoSummary: UndoSummary?

    private var work: Task<Void, Never>?

    private let guardian: RemovalGuard
    private let service: RemovalService
    private let undoService: UndoService

    init(
        guardian: RemovalGuard = RemovalGuard(),
        service: RemovalService? = nil,
        undoService: UndoService = UndoService()
    ) {
        self.guardian = guardian
        self.service = service ?? RemovalService(guardian: guardian)
        self.undoService = undoService
    }

    var isConfirming: Bool { plan != nil }

    /// What the confirmation will offer as its action. Trash unless the volume has none, in which
    /// case saying "Move to Trash" would be a promise the system cannot keep.
    var canTrash: Bool { plan?.trashAvailable ?? false }

    // MARK: - Asking

    func propose(_ candidates: [RemovalCandidate]) {
        guard !candidates.isEmpty else { return }
        deletePermanently = false
        plan = guardian.evaluate(candidates)
    }

    func cancelConfirmation() {
        plan = nil
        deletePermanently = false
    }

    // MARK: - Doing

    func confirm() {
        guard let plan, !plan.isEmpty else {
            cancelConfirmation()
            return
        }
        let disposition: Disposition =
            deletePermanently || !plan.trashAvailable ? .deletedPermanently : .trash

        self.plan = nil
        deletePermanently = false
        isRemoving = true
        removedCount = 0
        plannedCount = plan.permitted.count
        summary = nil
        undoSummary = nil

        work = Task { [service] in
            for await event in service.perform(plan, disposition: disposition) {
                switch event {
                case .removed:
                    self.removedCount += 1
                case .failed:
                    break
                case let .finished(result):
                    self.summary = result
                    self.undoAvailability = self.undoService.availability(
                        of: result.removed, disposition: result.disposition
                    )
                }
            }
            self.isRemoving = false
        }
    }

    /// Stops the batch starting anything further. What has already gone stays gone, and the
    /// summary says so rather than presenting a half-done run as a clean abort (FR-056).
    func cancel() {
        work?.cancel()
    }

    func dismissSummary() {
        summary = nil
        undoSummary = nil
    }

    // MARK: - Taking it back

    func performUndo(of items: [RemovedItem], onFinished: @escaping (UndoSummary) -> Void) {
        guard !isUndoing else { return }
        isUndoing = true
        undoSummary = nil

        work = Task { [undoService] in
            var result = UndoSummary(restored: [], failures: [])
            for await event in undoService.undo(items) {
                if case let .finished(summary) = event { result = summary }
            }
            self.undoSummary = result
            self.undoAvailability = .unavailable(result.wasComplete ? .trashEmptied : .failed)
            self.isUndoing = false
            onFinished(result)
        }
    }
}
