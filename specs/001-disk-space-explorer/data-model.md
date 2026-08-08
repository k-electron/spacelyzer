# Phase 1 Data Model: Disk Space Explorer

**Date**: 2026-08-08
**Spec**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

The model splits along a hard line. Session data describes one scan, can reach a million nodes, is
never written to disk, and is optimised for traversal and aggregation. Durable data is small,
long-lived, and belongs in SwiftData. Nothing about a user's files is durable except the paths they
themselves chose to remember.

---

## Session data (in memory)

### NodeStore

The scanned tree, stored as parallel arrays indexed by a 32-bit `NodeID` rather than as linked
objects. One object per file would breach the 500 MB memory constraint at a million items and would
make aggregation chase pointers across the heap.

Children of a node occupy a contiguous index range, which is possible because children are appended
together when their parent's directory is enumerated. Traversal of a subtree is therefore a range
scan rather than a pointer walk, and the treemap's per-frame work stays cache-friendly.

| Field | Type | Meaning |
|---|---|---|
| `parent` | `NodeID?` | Absent only for the scan root |
| `childRange` | `Range<NodeID>` | Empty for leaves |
| `nameRef` | `StringRef` | Index into an interned name table; paths are reconstructed by walking parents |
| `kind` | `Kind` | `file`, `directory`, `package`, `symlink`, or `remainder` |
| `category` | `Category` | Derived once from the item's type identifier |
| `ownSize` | `Int64` | Allocated size of the item itself, zero for directories |
| `cumulativeSize` | `Int64` | `ownSize` plus every descendant, filled in on completion |
| `itemCount` | `Int32` | Descendant count including self |
| `created`, `modified`, `accessed` | `Date` | As reported by the filesystem |
| `flags` | `OptionSet` | `countedElsewhere`, `unreadable`, `excluded` |

**Invariants**, each traceable to a requirement:

- A node's `cumulativeSize` equals its `ownSize` plus the `cumulativeSize` of its children (FR-008).
- Any node carrying `countedElsewhere` contributes zero to every ancestor's `cumulativeSize`; this
  is how a hard-linked file appears at all its paths while its bytes are counted once (FR-006).
- A `symlink` node never has children (FR-007).
- A `remainder` node has no filesystem counterpart. It exists only in a layout to represent
  siblings too small to draw and carries their combined size and count (FR-032).
- Names are interned. Path strings are never stored per node.

### Scan

One measurement of one root, and the owner of a `NodeStore`.

| Field | Type | Notes |
|---|---|---|
| `root` | `URL` | The location the user selected |
| `startedAt`, `finishedAt` | `Date` | `finishedAt` absent while running |
| `state` | `ScanState` | See lifecycle below |
| `measuredTotal` | `Int64` | Sum of counted bytes |
| `volumeContext` | `VolumeContext?` | Absent when the root is not on a mounted volume |
| `skipped` | `[SkippedLocation]` | Everything unreadable (FR-005) |
| `unaccounted` | `[UnaccountedEntry]` | The reconciliation (FR-016) |
| `exclusionsApplied` | `[ExclusionRule]` | Snapshot of rules at scan time |

**Lifecycle**. A scan moves `idle → requestingAccess → scanning → completed`, and from `scanning`
it may instead reach `cancelled`, which retains every node measured so far and marks the result
incomplete (FR-004). A `completed` or `cancelled` scan becomes `stale` when the exclusion list
changes, which surfaces the "no longer reflects current settings" state required by FR-013 without
mutating any measurement. Nothing transitions out of `stale` except a new scan.

### VolumeContext and UnaccountedEntry

`VolumeContext` records `totalCapacity`, `availableCapacity`, and
`availableCapacityForImportantUsage` for the volume holding the root. Purgeable space is derived as
the difference between the last two, per research R4.

`UnaccountedEntry` is one named cause with a size, and the list of them is what makes SC-008
enforceable: the reconciliation is only complete when measured total plus every entry equals the
volume's used space. Causes are `permissionDenied`, `userExcluded`, `purgeable`, and
`unattributed`. The last carries an explanation naming its usual contributors — local snapshots,
sibling volumes in the same container, and cloned blocks — because research R4 established that
those cannot be sized individually from inside the sandbox.

### Selection

A single optional `NodeID` plus the identity of the view that last changed it. There is exactly one
of these per scan, shared by the outline and the treemap (FR-035). It is not two synchronised
selections, and research R7 makes this load-bearing for accessibility rather than merely tidy.

When the treemap's displayed root changes so that the selection is no longer inside it, the
selection resolves to the nearest ancestor that is, or clears if there is none (FR-036).

### Filter

The active narrowing, applied to both views at once (FR-042).

| Field | Type | Requirement |
|---|---|---|
| `nameContains` | `String?` | FR-037, matched case-insensitively |
| `categories` | `Set<Category>` | FR-038 |
| `extensions` | `Set<String>` | FR-038 |
| `minSize`, `maxSize` | `Int64?` | FR-039 |
| `modifiedRange` | `ClosedRange<Date>?` | FR-040 |

Filters combine conjunctively, and an empty filter matches everything. Evaluation produces a
`FilterResult` holding a bitmap over `NodeID` plus the match count and combined size required by
FR-043. A bitmap rather than a node list is what keeps re-evaluation within SC-009's 200 ms at a
million nodes, and lets the treemap test membership in constant time while drawing.

### CategoryBreakdown

An array of `CategoryTotal` — category, combined size, item count, share of scan — ranked by size
(FR-044). Computed by one pass over the node store, which is why SC-010 can promise it without a
rescan.

### DuplicateSet

A group of two or more `NodeID`s whose contents are identical, with `recoverableSize` equal to the
total size of all but the largest-path-stable copy. Sets are ranked by `recoverableSize` (FR-064).

A set carries the constraint that at least one member must survive any removal, and this is
enforced on the set itself rather than in the UI, so that FR-065 cannot be bypassed by a different
entry point.

### TreemapLayout

The output of laying out a displayed root: an array of `LaidOutRect` pairing a `NodeID` with its
frame and depth, plus a spatial index for hit testing. Layout is a pure function of node sizes and
the available rectangle, with siblings ordered by descending size and ties broken by name, so the
same data always produces the same picture (research R6).

---

## Durable data (SwiftData)

Four small record types. None of them stores a scan.

### ExclusionRule

A folder the user has chosen to leave out, holding a `bookmark` for durable reference, a
`displayPath` for showing in settings, and `createdAt`. Validation refuses a rule whose target is
the current scan root (FR-012). Adding or removing a rule marks any existing scan `stale` (FR-013).

### RecentLocation

A previously scanned root: `bookmark`, `displayPath`, `lastScannedAt`, and `lastMeasuredTotal` for
display before a rescan completes. The bookmark is what makes FR-009's "return to recent locations
without navigating to them again" possible at all, since the sandbox grants no standing access.
Resolution checks `isStale` and re-saves, and a location whose volume is absent is shown as
unavailable rather than being deleted.

### RemovalHistoryEntry

One completed removal batch: `performedAt`, `disposition` of `trashed` or `deletedPermanently`,
`spaceFreed`, `itemCount`, and an `undoState` of `undoable`, `undone`, or `unrestorable`. It owns
an ordered list of `RemovedItemRecord`, each holding `originalPath`, `trashURL` where applicable,
`size`, and `outcome`.

The `trashURL` is the only reliable handle for restoring an item, because the system renames on
collision. Capturing it at removal time is what makes undo implementable (FR-059), and its absence
is what makes a permanent deletion honestly reportable as unrestorable rather than as a failed undo
(FR-060).

### Preferences

`sizeUnitConvention` of `decimal` or `binary` (FR-020, FR-021) and
`duplicateMinimumFileSize`, the adjustable threshold below which duplicate detection skips files.

---

## What is deliberately absent

No scan is persisted. Comparison between scans is out of scope in the spec, which removes the only
reason to keep one, and persisting a full index of someone's disk would create the single most
sensitive artifact this app could hold — exactly what Principle I exists to prevent. Recent
locations store a bookmark and a total, not contents.

No file contents are retained. Duplicate detection streams and hashes, and preview is rendered out
of process by Quick Look.
