# Contract: Access and Scanning

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

These are internal interfaces between the scanning capability and the rest of the app. They exist
so that traversal, accounting, and access brokering can be tested against fixture trees with no
interface running, which Principle IV requires.

---

## AccessBroker

Owns every interaction with the sandbox boundary. No other component may resolve a bookmark or
start a security scope.

```swift
protocol AccessBroker {
    func requestScanRoot() async throws -> AccessGrant
    func resolve(_ bookmark: Data) throws -> AccessGrant
    func grantForRemoval(of paths: [URL]) async throws -> AccessGrant
}

protocol AccessGrant: AnyObject {
    var url: URL { get }
    var bookmark: Data { get }
    var isStale: Bool { get }
}
```

**Contract**

- `requestScanRoot` presents a system open panel. There is no other way to obtain a root, because a
  sandboxed app cannot widen its own reach (research R1). It must never be called speculatively;
  only in response to a user action.
- An `AccessGrant` holds an active security scope for its lifetime and releases it on deinit. Every
  start is matched by exactly one stop; leaked scopes eventually cause the system to refuse further
  grants, which surfaces as unexplained permission failures much later.
- `resolve` reports `isStale` rather than hiding it. The caller re-saves the returned bookmark when
  stale, or reports the location unavailable when resolution fails, and never treats an unavailable
  location as an empty one.
- Read scope is requested read-only. Read-write is requested only through `grantForRemoval`, and
  only for paths the user has already confirmed.

---

## ScanEngine

```swift
protocol ScanEngine {
    func scan(
        root: AccessGrant,
        excluding: [ExclusionRule],
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanEvent, Error>
}

enum ScanEvent {
    case progress(measuredBytes: Int64, itemsSeen: Int, currentPath: String)
    case skipped(SkippedLocation)
    case completed(NodeStore, totals: ScanTotals)
    case cancelled(NodeStore, totals: ScanTotals)
}
```

**Contract**

- The stream is the only output. The engine never touches view state and is not main-actor bound
  (Principle III).
- `progress` events are coalesced to a fixed cadence, not emitted per file. A million individual
  updates would freeze the interface that exists to display them.
- Cancellation is checked at every directory batch boundary, bounding latency to one directory's
  enumeration and satisfying FR-004 and SC-003. On cancellation the engine emits `.cancelled`
  carrying the partial store — it does not discard measured work and does not throw.
- An unreadable entry produces a `.skipped` event and traversal continues (FR-005). Only a failure
  that makes the whole scan meaningless, such as the root becoming unavailable, throws.
- Each unit of stored data is counted once. Entries with a link count above one are recorded at
  every path but contribute bytes only at the first (FR-006).
- Symbolic links are recorded and never followed (FR-007).
- Excluded subtrees are skipped during enumeration rather than filtered afterwards, so exclusion
  costs nothing to apply.
- Sizes are allocated size, never logical length.

**Testability requirement**: The engine reads through a `FileSystemProvider` seam so tests can
drive it against a constructed temporary tree. No test may enumerate a real home directory, and no
fixture path may be hardcoded to a developer's machine (Principle IV).

---

## VolumeAccountant

```swift
protocol VolumeAccountant {
    func context(for root: URL) throws -> VolumeContext?
    func reconcile(
        measured: Int64,
        skipped: [SkippedLocation],
        exclusions: [ExclusionRule],
        context: VolumeContext
    ) -> [UnaccountedEntry]
}
```

**Contract**

- `reconcile` must return entries whose sizes, added to `measured`, equal the volume's used space
  within the 1% tolerance of SC-007. When attribution falls short, the shortfall is emitted as an
  `unattributed` entry with an explanation. It is never dropped and never silently absorbed into
  another category, because SC-008 forbids presenting any gap without a stated cause.
- Purgeable space is derived as available-for-important-usage minus available capacity (research
  R4).
- The accountant does not attempt to size local snapshots. No public API exposes them inside the
  sandbox, and pretending otherwise would produce a confidently wrong number. Their space arrives
  in the `unattributed` entry, whose explanation names them.
- `context` returns nil rather than throwing when the root is not on a mounted volume; scanning a
  plain folder is still valid, it simply has nothing to reconcile against.
