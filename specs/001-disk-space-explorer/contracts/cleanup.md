# Contract: Duplicates, Guards, and Removal

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

This is the only part of the app that destroys anything, and Principle II is non-negotiable, so
these contracts are stricter than the rest. Guards are evaluated in the model layer, never in a
view, so that no future entry point can reach removal without passing them.

---

## RemovalGuard

```swift
protocol RemovalGuard {
    func evaluate(_ candidates: [NodeID], in store: NodeStore) -> RemovalPlan
}

struct RemovalPlan {
    let permitted: [PlannedRemoval]     // path, size
    let refused: [RefusedRemoval]       // path, reason
    let totalReclaimable: Int64
    let trashAvailable: Bool
}
```

**Contract**

- Evaluation happens *before* the confirmation is shown, so refusals are visible while the user is
  deciding rather than arriving as failures afterwards (FR-055).
- Refusal is mandatory for protected system locations, the app's own container, and any path
  outside the granted security scope. A refused item never appears in `permitted`.
- Refusing some candidates never blocks the rest (FR-055).
- `trashAvailable` is determined for the target volume up front, because FR-053's default disposal
  must be known to be possible before the user is told it will happen; some volumes cannot Trash.
- A plan is a value. Producing one has no side effects and removes nothing, which makes the guard
  exhaustively unit-testable against fixture trees, as Principle II's coverage requirement demands.

---

## RemovalService

```swift
protocol RemovalService {
    func perform(
        _ plan: RemovalPlan,
        disposition: Disposition,
        grant: AccessGrant
    ) -> AsyncStream<RemovalEvent>
}

enum Disposition { case trash, deletePermanently }

enum RemovalEvent {
    case removed(path: URL, trashURL: URL?, size: Int64)
    case failed(path: URL, reason: RemovalFailure)
    case finished(RemovalHistoryEntry)
}
```

**Contract**

- Only a `RemovalPlan` can be executed. There is no path that takes raw URLs, so the guard cannot
  be bypassed.
- `disposition` defaults to `.trash` at every call site. `.deletePermanently` is reachable only
  from an explicit, separately confirmed user choice carrying an irreversibility warning (FR-054).
- Each trashed item's resulting Trash URL is captured and recorded. It is the only reliable handle
  for restoration because the system renames on collision, and without it undo cannot work
  (research R10).
- An individual failure emits `.failed` and the batch continues (FR-056). The run is cancellable,
  and cancelling stops further removals without rolling back completed ones — which is reported
  honestly in the summary rather than presented as a clean abort.
- `.finished` always arrives, including after cancellation, carrying the history entry that records
  what actually happened.
- Nothing here is ever invoked by scanning, browsing, sorting, filtering, or navigating (FR-058).
- Progress is shown while a batch runs, and the rest of the interface stays usable. The cancel
  control in particular must remain reachable throughout, since Principle III forbids background
  work from blocking its own cancellation. A modal that locks the window until removal finishes
  violates this.

---

## UndoService

```swift
protocol UndoService {
    func canUndo(_ entry: RemovalHistoryEntry) -> UndoAvailability
    func undo(_ entry: RemovalHistoryEntry, grant: AccessGrant) -> AsyncStream<UndoEvent>
}

enum UndoEvent {
    case restored(path: URL)
    case failed(path: URL, reason: UndoBlocked)
    case finished(UndoOutcome)
}

enum UndoAvailability {
    case available
    case unavailable(reason: UndoBlocked)   // trashEmptied, originalLocationMissing, wasPermanent
}
```

**Contract**

- Only the most recent batch is undoable, matching the spec's assumption. Older removals stay
  recoverable by hand from the Trash but are not restorable through the app.
- `canUndo` is checked and surfaced before the action is offered, so the user is not invited to
  press something that cannot work.
- A partial restoration reports exactly which items returned and which did not. Reporting a
  successful undo that did not fully occur is a contract violation and is specifically forbidden by
  FR-060.
- After a successful undo the history entry moves to `undone`; after a failed one it moves to
  `unrestorable` with the reason retained.
- Restoration streams per-item events rather than returning a single value at the end. Moving a
  large batch out of the Trash can take longer than two seconds, and Principle III requires
  incremental progress rather than an interface that appears to have stopped.

---

## DuplicateFinder

```swift
protocol DuplicateFinder {
    func findDuplicates(
        in store: NodeStore,
        minimumSize: Int64
    ) -> AsyncThrowingStream<DuplicateEvent, Error>
}
```

**Contract**

- Three stages in increasing cost: group by exact allocated size, then compare a bounded prefix
  hash, then compare a full streamed SHA-256 (research R9). Only the final stage may declare
  identity.
- Matching name, size, or date is never sufficient to report a duplicate (FR-063). Two files of
  equal size with differing content must not appear as a set, and this is a required test case.
- Progress is reported per stage and cancellation is checked between files (FR-066).
- Every emitted set contains at least two members and carries `recoverableSize` equal to the total
  of all but one copy.
- A `DuplicateSet` refuses to yield a removal selection that would include all of its members
  (FR-065). This is enforced on the set, not by the view, so no alternative entry point can delete
  the last copy.
- File contents are streamed and never retained beyond the hashing window.
