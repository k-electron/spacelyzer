# Contract: Duplicates, Guards, and Removal

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

This is the only part of the app that destroys anything, and Principle II is non-negotiable, so
these contracts are stricter than the rest. Guards are evaluated in the model layer, never in a
view, so that no future entry point can reach removal without passing them.

---

## RemovalGuard

```swift
struct RemovalGuard {
    func evaluate(_ candidates: [RemovalCandidate]) -> RemovalPlan
    /// Nil means it may go. Everything else names the reason it may not.
    func refusal(for url: URL) -> RemovalRefusal?
}

struct RemovalCandidate { let url: URL; let size: Int64 }

struct RemovalPlan {
    let permitted: [PlannedRemoval]     // url, size
    let refused: [RefusedRemoval]       // url, reason
    var totalReclaimable: Int64
    let trashAvailable: Bool
}
```

A candidate carries the size the scan already measured rather than the guard reading it. A
folder's size is the sum of everything beneath it, and rediscovering that here would mean walking
the disk at the moment the user is waiting on a dialog.

`refusal(for:)` is public on the guard rather than internal to `evaluate`, because the service
calls it again per item at the moment of removal.

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
struct RemovalService {
    init(guardian: RemovalGuard)
    func perform(_ plan: RemovalPlan, disposition: Disposition) -> AsyncStream<RemovalEvent>
}

enum Disposition { case trash, deletedPermanently }

enum RemovalEvent {
    case removed(RemovedItem)               // originalPath, trashPath, size
    case failed(RemovalFailureRecord)       // path, reason
    case finished(RemovalSummary)
}
```

No access grant: the app is unsandboxed, so removal has the same reach as the scan and there is no
scope to carry. `finished` yields a value summary rather than a stored record — the service runs
off the main actor and a persistent model cannot cross that boundary, so the window records what
came back.

**Contract**

- Only a `RemovalPlan` can be executed. There is no entry point taking raw URLs.
- A plan is a value, and a value can be constructed by anyone. So the guard is consulted a second
  time, per item, immediately before that item moves. Passing a hand-built plan is therefore not a
  way around the guard, only a way to be refused later than usual.
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
struct UndoService {
    func availability(of items: [RemovedItem], disposition: Disposition) -> UndoAvailability
    func undo(_ items: [RemovedItem]) -> AsyncStream<UndoEvent>
}

enum UndoEvent {
    case restored(RestoredItem)
    case failed(UndoFailureRecord)          // path, reason
    case finished(UndoSummary)
}

enum UndoAvailability {
    case available
    case unavailable(UndoBlocked)
    // trashEmptied, originalLocationMissing, wasPermanent, somethingIsThereNow, failed
}
```

Takes the removed items as values rather than the stored entry, for the same reason the service
returns one: this runs off the main actor. The window reads the entry and hands over its contents.

`somethingIsThereNow` was added during implementation. Whatever occupies the original path arrived
after the removal, and writing over it would be a second deletion nobody asked for — so it is a
refusal with a name rather than a silent overwrite.

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
        under root: ScannedItem,
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
