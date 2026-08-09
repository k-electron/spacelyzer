# Contract: Access and Scanning

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

These are internal interfaces between the scanning capability and the rest of the app. They exist
so that traversal, accounting, and access brokering can be tested against fixture trees with no
interface running, which Principle IV requires.

**Shared types used across all three contract files.** `ScannedItem` is the value type described in
[data-model.md](../data-model.md): a node in the scan tree, owning its children. A whole scan is
therefore just its root `ScannedItem`. Where a subset of the scan needs passing around, it is
carried as a set of paths rather than of object identifiers, since values have no identity of
their own.

These replaced a SwiftData-backed `NodeStore` and `NodeID`; research R5 records the measurement
that removed them.

---

## AccessBroker

Owns everything to do with what the app is permitted to read. The app runs unsandboxed, so the
constraint is no longer the sandbox but the system's privacy protections.

```swift
protocol AccessBroker {
    func mountedVolumes() -> [VolumeDescriptor]
    func chooseFolder() async -> URL?
    var fullDiskAccess: FullDiskAccessState { get }
    func openFullDiskAccessSettings()
    func protectedLocationsUnreadable() -> [URL]
}

enum FullDiskAccessState { case granted, notGranted, unknown }
```

**Contract**

- `mountedVolumes` enumerates volumes directly, which is what FR-001's volume picker requires. This
  became possible only when the sandbox was dropped in constitution v2.0.0.
- `chooseFolder` remains available for scanning an arbitrary folder, but it is a convenience rather
  than the only route to access, which is what it was under the sandbox.
- `fullDiskAccess` is determined by attempting to read a location the system protects and observing
  the outcome. There is no API that reports the grant directly, so the state is inferred and
  `unknown` is a legitimate answer that must be handled rather than coerced to a boolean.
- `openFullDiskAccessSettings` takes the user to the relevant System Settings pane. The app MUST
  NOT claim it requires the privilege, and MUST remain useful without it (constitution v2.0.0,
  Platform and Technology Constraints).
- `protectedLocationsUnreadable` drives FR-018: before results are shown, the user is told which
  locations will be missing, named individually rather than as a vague warning.
- The grant usually takes effect only after relaunch, so the app watches for the state changing and
  offers a rescan (FR-019) rather than assuming a running process gains access mid-session.
- No security-scoped bookmark is needed for access any more. `RecentLocation` may still store one
  as a durable, rename-resilient reference to a path, which is a different purpose.

---

## ScanEngine

```swift
protocol ScanEngine {
    func scan(
        root: AccessGrant,
        excluding: [ExclusionRule],
        options: ScanOptions
    ) -> AsyncThrowingStream<ScanEvent, Error>

    func expandPackage(at url: URL, options: ScanOptions) async -> ScannedItem
}

enum ScanEvent {
    case progress(measuredBytes: Int64, itemsSeen: Int, currentPath: String)
    case skipped(SkippedLocation)
    case completed(root: ScannedItem, totals: ScanTotals)
    case cancelled(root: ScannedItem, totals: ScanTotals)
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
- Sizes are allocated size, never logical length. Logical length is not collected during the scan;
  `ItemInspector` reads it for the single item being inspected.
- Application bundles are measured whole but not enumerated during the main pass, so they arrive as
  single items (FR-022). `expandPackage` performs a targeted pass over one bundle when the user
  opens it, returning the measured subtree. It is called only in response to that explicit action,
  never speculatively, and like any other operation it reports that it is working if it runs long.

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
- Snapshot sizes come from `diskutil apfs listSnapshots`, isolated behind one interface that treats
  the tool's output as untrusted and changeable. When the tool is missing, its output does not
  parse, or a size cannot be derived, the space falls through to `unattributed` with the reason
  stated. It is never reported as zero, because a confidently wrong number is worse here than an
  admitted unknown.
- Snapshot sizes are estimates that drift. A snapshot shares blocks with the live filesystem, so
  the space unique to it grows as the volume diverges. The accountant labels these as current
  estimates rather than fixed properties.
- `context` returns nil rather than throwing when the root is not on a mounted volume; scanning a
  plain folder is still valid, it simply has nothing to reconcile against.
