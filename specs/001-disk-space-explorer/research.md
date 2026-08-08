# Phase 0 Research: Disk Space Explorer

**Date**: 2026-08-08
**Spec**: [spec.md](./spec.md)
**Constitution**: [.specify/memory/constitution.md](../../.specify/memory/constitution.md) v1.3.0

Every unknown carried into planning is resolved below. Two findings change the shape of the
design and one conflicts with the specification as written; those are called out explicitly.

---

## R1. How the app gets permission to read the disk

**Decision**: Access is obtained exclusively through a system open panel in which the user selects
the folder or volume to scan, and is persisted across launches with an app-scoped security-scoped
bookmark created with `.withSecurityScope` and `.securityScopeAllowOnlyReadAccess`. The app
declares `com.apple.security.files.user-selected.read-only`, and requests read-write scope only for
locations the user has chosen to clean up. Every resolved bookmark is wrapped in a matched
`startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource` pair with `defer`,
and `isStale` is checked on every resolve and re-saved when set.

**Rationale**: The constitution requires App Sandbox to remain enabled in all configurations, and a
sandboxed app cannot widen its filesystem reach through an entitlement or through code. The only
mechanism that grants access is a user action — an open panel selection or a drag — which causes
the system to issue a dynamic sandbox extension to the process. That extension dies with the
process, so a bookmark is the only way to avoid re-prompting on every launch. Accepting this early
also keeps the undecided distribution channel open, which the constitution requires.

**Consequences worth stating plainly**: To scan an entire volume the user must select that volume's
root in the open panel. The app cannot present its own volume list and start scanning from it, and
it cannot silently widen its own access. Full Disk Access is a separate, user-granted privilege in
System Settings that the app must never demand and, for a sandboxed build, must not depend on;
App Store review reacts badly to apps that require it. The design therefore treats broad access as
something the user confers by choosing a root, not as a precondition.

**Alternatives considered**: Shipping unsandboxed with Full Disk Access would allow enumerating
volumes directly, but it violates the constitution's sandbox requirement and forecloses App Store
distribution while that decision is still open. A privileged helper tool was rejected because it
does not reliably inherit the privacy privileges it would need and adds a large security surface
for a read-mostly utility.

---

## R2. Directory traversal API

**Decision**: Use `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`
with an explicit, minimal set of resource keys prefetched in the same call, an `errorHandler` that
records unreadable entries and returns `true` to continue, and an `autoreleasepool` around each
batch. Use `skipDescendants()` to implement user exclusions, and `.skipsPackageDescendants` to
present application bundles as single items.

**Rationale**: The URL-based enumerator is built on the same bulk kernel interface as
`getattrlistbulk`, so it makes one system call per batch of entries rather than one `stat` per
file, which is the dominant cost when walking millions of files. Apple's own guidance is to prefer
it over `getattrlistbulk` directly, which requires manual buffer management and output parsing for
little or no gain. Prefetching resource keys matters more than the choice of enumerator: requesting
attributes afterwards reintroduces the per-file round trip the bulk call exists to avoid.
`skipDescendants` gives exclusions for free, without a post-filter over results.

**Alternatives considered**: `getattrlistbulk` was rejected as high-complexity for no measured
benefit on local APFS. `fts(3)` benchmarks marginally faster on APFS in third-party testing but is
a C interface with awkward lifetime management, and the margin does not justify it before any
measurement shows the Foundation path failing SC-001. The path-based `enumerator(atPath:)` is
disqualified outright: its contract forces a `stat` per entry.

---

## R3. What a byte means, and counting it once

**Decision**: Report `totalFileAllocatedSize` — space actually occupied on disk — matching the
spec's stated assumption. Deduplicate hard links by tracking the pair of `volumeIdentifier` and
`fileIdentifier` for any entry whose link count exceeds one, attributing the bytes to the first
path encountered and recording later paths at zero. Symbolic links are recorded as entries with
their own trivial size and are never followed.

**Rationale**: A tool whose purpose is reclaiming space must report the space that reclaiming would
return, which is allocated size, not logical length. Sparse and compressed files make the two
diverge substantially. Restricting the identity map to multiply-linked files keeps its memory cost
proportional to a rare case rather than to the whole scan.

**Known imprecision to disclose, not hide**: APFS clones share physical blocks while each clone
reports its full allocated size, so a volume containing many clones will measure larger than the
space that deleting everything would actually free. There is no public API that attributes shared
blocks to a single owner. This is one contributor to the reconciliation gap in R4 and must be
surfaced there rather than silently absorbed.

---

## R4. Volume capacity, purgeable space, and the unaccounted remainder

**Decision**: Read `volumeTotalCapacityKey`, `volumeAvailableCapacityKey`, and
`volumeAvailableCapacityForImportantUsageKey` from the volume holding the scan root. Derive
purgeable space as the difference between capacity available for important usage and strictly
available capacity. Present the reconciliation as: measured total, plus permission-denied
locations, plus user exclusions, plus purgeable space, plus a named residual category for space
the app cannot attribute.

**Rationale**: These are the same figures Disk Utility surfaces; they originate from the system's
CacheDelete subsystem rather than from APFS directly, which is why they disagree with the Finder's
cached values. Available capacity already includes purgeable space, so subtracting gives the
purgeable figure without a private interface.

**Conflict with the specification**: FR-017 requires naming space held by system snapshots as a
distinct category *with its size*. This is not achievable from within the App Sandbox. Local
snapshot inventory is available through `tmutil`, which a sandboxed app cannot invoke, and there is
no public API exposing per-snapshot sizes. Snapshots also count as used space rather than purgeable
space, so they do not appear in the purgeable figure either. In an APFS container, space consumed
by sibling volumes is likewise invisible.

**Resolution proposed**: Relax FR-017 so that snapshots are not required to be an independently
sized category. Report instead a named residual — space present on the volume that this app cannot
see — accompanied by a plain-language explanation naming its usual contributors: local snapshots,
other volumes sharing the container, and cloned blocks counted once by the filesystem. SC-007's 1%
reconciliation target then applies to the whole accounting including that residual, which keeps the
user-facing promise in SC-008 intact: no gap is ever shown without a stated cause. **This requires
a spec amendment before implementation and is recorded as a gate item in plan.md.**

**Alternatives considered**: Shelling out to `tmutil` is impossible under sandbox. Dropping the
sandbox to gain snapshot visibility trades a constitutional requirement for one reporting line and
was rejected. Silently folding snapshots into the residual without naming them would violate
FR-016 and SC-008.

---

## R5. Where scan results live

**Decision**: Hold the scanned tree in memory for the duration of a session as a compact value-type
structure in contiguous storage, indexed by integer node identifiers rather than object references.
Use SwiftData only for small durable records: exclusion rules, recently scanned locations with
their bookmarks, removal history, and preferences. **This deviation from SwiftData for scan results
is provisional and must be validated by measurement before it is treated as settled.**

**Rationale**: The constitution requires SwiftData for persistence unless a recorded measurement
shows it cannot meet a stated requirement. The stated requirements here are severe: 500,000 items
measured in under 60 seconds, filters applied across 1,000,000 items in under 200 milliseconds, and
a treemap that stays responsive at that scale. Those are in-memory numbers. A managed object graph
with a million rows, recursive size rollups, and predicate evaluation per filter keystroke is very
unlikely to reach them. An integer-indexed array of nodes also makes the parent and child links
cheap and keeps per-node overhead to tens of bytes.

**Obligation this creates**: Per Principle V the measurement must actually be taken and recorded,
not assumed. The first implementation task is a benchmark comparing both storage approaches on a
fixture tree of at least 500,000 nodes against SC-001 and SC-009. If SwiftData meets the targets,
the constitution requires using it. The result is recorded in this file.

**Alternatives considered**: Persisting completed scans to disk for later reload was rejected for
this feature because comparison between scans is explicitly out of scope, which removes the main
reason to keep them. A memory-mapped custom file format is a possible future optimisation and is
premature now.

---

## R6. Treemap layout and rendering

**Decision**: Lay out rectangles with the squarified treemap algorithm, ordering siblings by
descending size with a deterministic tie-break on name so that layout is reproducible for identical
input. Render through a single SwiftUI `Canvas` in immediate mode rather than one view per item.
Stop descending when a node's rectangle falls below a minimum drawable area and draw the collapsed
children as one labeled remainder region. Hit-test through a spatial index built from the laid-out
rectangles rather than by walking the tree.

**Rationale**: Squarified layout keeps aspect ratios near square, which is what makes area
differences visually comparable; strip and slice-and-dice layouts produce slivers that defeat the
purpose. One view per item is impossible at a million items, whereas immediate-mode drawing costs
only what is actually visible. The minimum-area cutoff is what makes FR-032's remainder region a
natural consequence of the layout rather than a special case bolted on. Deterministic ordering
means a rescan of unchanged data produces an identical picture, so rectangles do not shuffle.

**Alternatives considered**: Metal was rejected as premature; `Canvas` should be measured first.
Voronoi treemaps look striking but make area comparison harder and cost far more to compute.

---

## R7. Making the treemap usable without sight

**Decision**: The hierarchy outline is the accessible representation of the same data, and every
operation reachable from the treemap is reachable from the outline. The treemap additionally
exposes an accessibility element tree mirroring the currently drawn nodes, each labeled with name,
size, and share of the displayed total, with the selection following VoiceOver focus through the
same shared selection that binds the two views.

**Rationale**: The constitution requires VoiceOver support and keyboard navigation. A treemap is
the hardest possible case for a screen reader, and the honest answer is that area is not an
accessible encoding. Rather than annotating a canvas and calling it done, the design leans on the
fact that the spec already requires a synchronised outline and a single shared selection: that
outline is a complete, navigable, textual equivalent. Exposing drawn nodes as accessibility
elements then makes the graphical view itself navigable rather than opaque.

**Consequence**: The shared selection model in FR-035 becomes load-bearing for accessibility, not
merely a convenience. It cannot be implemented as two loosely synchronised selections.

---

## R8. Concurrency, cancellation, and responsiveness

**Decision**: Model the scan as an `AsyncStream` of progress events produced by a detached task,
with subtree traversal fanned out across a `TaskGroup` bounded to the active processor count.
Aggregate into an actor-isolated accumulator. Check for cancellation at every directory batch
boundary. Keep all mutation of view state on the main actor and publish coalesced snapshots at a
fixed cadence rather than per file. Adopt Swift 6 language mode.

**Rationale**: Batch-boundary cancellation checks bound worst-case cancellation latency to the time
to finish one directory, which comfortably satisfies the one-second requirement in FR-004 and
SC-003. Coalescing progress prevents the UI from being flooded by millions of updates, which is the
usual cause of a scanner freezing the very interface that is meant to show progress. Swift 6
language mode is chosen because this design is concurrency-dense and compile-time data-race
checking is far cheaper than debugging a race across an actor boundary; the project is greenfield,
so there is no migration cost, and approachable concurrency is already enabled in the build
settings.

**Alternatives considered**: Unbounded task fan-out was rejected because it thrashes on I/O-bound
work. Serial traversal is simpler but leaves parallelism unused on machines that have it.

---

## R9. Duplicate detection

**Decision**: Three stages, each cheaper than the next. Group candidates by exact allocated size;
within each group of two or more, compare a hash of a bounded prefix; only for files still matching,
compare a full-content SHA-256 computed with CryptoKit over a streamed read. Files below a
user-adjustable size threshold are skipped by default. Report progress per stage and check for
cancellation between files.

**Rationale**: The overwhelming majority of files are eliminated by size alone at effectively zero
I/O cost, and most of the survivors are eliminated by the prefix hash. Only genuine candidates are
read in full, which is what keeps SC-015's five-minute budget over 100,000 files achievable.
SHA-256 from CryptoKit is a platform capability, so it introduces no dependency and needs no
justification under Principle VI. FR-063 forbids treating name or size alone as proof of identity,
which is why the full-content stage is not optional.

**Alternatives considered**: A faster non-cryptographic hash would need a third-party dependency,
which Principle VI defaults to refusing, for a stage that is not the bottleneck. Byte-by-byte
comparison of candidate pairs is exact but degrades badly when a set has many members.

---

## R10. Removal, Trash, and undo

**Decision**: Remove with `FileManager.trashItem(at:resultingItemURL:)`, capturing the returned
Trash URL for every item in the batch. Undo moves each item from its recorded Trash URL back to its
original location, verifying both that the Trash item still exists and that the original parent
directory still exists, and reporting precisely which items could not be restored. Permanent
deletion uses `removeItem` and is recorded as unrestorable. Protected locations are refused by
checking candidate paths against the scan root's volume, the system volume, and the app's own
container before the confirmation is even shown.

**Rationale**: The resulting Trash URL is the only reliable handle for restoring an item, since the
system renames on collision; capturing it at removal time is what makes FR-059 implementable at
all. Checking protections before the confirmation means FR-055's refusal is visible to the user
while they are deciding, rather than arriving as a failure afterwards. Read-write access for
removal comes from the same security scope as the scan.

**Alternatives considered**: Recording only original paths and searching the Trash at undo time is
unreliable under renaming. Implementing a general multi-level undo stack was rejected as out of
proportion to the spec, which requires undo of the most recent batch only.

---

## R11. Preview, reveal, and open

**Decision**: Preview with `QLPreviewView` bridged into SwiftUI through `NSViewRepresentable`.
Reveal with `NSWorkspace.activateFileViewerSelecting`. Open with `NSWorkspace.open`. When Quick
Look reports no available preview, show an explanatory placeholder carrying the item's metadata.

**Rationale**: All three are platform capabilities that function inside the sandbox for URLs the
user has already granted, so they add no entitlement surface and no dependency. Quick Look
generates previews out of process, so a malformed file cannot take the app down with it, which
matters when previewing arbitrary content found on someone's disk.

---

## R12. Summary of decisions requiring follow-up

| Item | Follow-up required |
|---|---|
| R4 snapshot sizing | Amend FR-017 before implementation; residual category replaces sized snapshots |
| R5 scan storage | Benchmark SwiftData against in-memory on 500,000 nodes; record result here |
| R8 Swift 6 mode | Change `SWIFT_VERSION` in build settings, which amends a fact stated in the constitution |
