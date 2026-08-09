# Phase 0 Research: Disk Space Explorer

**Date**: 2026-08-08
**Spec**: [spec.md](./spec.md)
**Constitution**: [.specify/memory/constitution.md](../../.specify/memory/constitution.md) v2.1.0

Every unknown carried into planning is resolved below. Two findings change the shape of the
design and one conflicts with the specification as written; those are called out explicitly.

---

## R1. How the app gets permission to read the disk

**Decision**: Spacelyzer ships without the App Sandbox, signed with a Developer ID identity,
Hardened Runtime enabled, and notarized. It enumerates mounted volumes directly and reads through
ordinary filesystem calls. Locations the system protects by privacy policy — Desktop, Documents,
Downloads, and similar — become readable once the user grants Full Disk Access in System Settings.
Until then those locations are reported as skipped, exactly like any other unreadable path.

**Rationale**: This was originally decided the other way, and the sandbox made three requirements
unimplementable. A sandboxed app cannot enumerate volumes, so FR-001's volume picker was impossible
and the user had to select a root in an open panel. It cannot reach the filesystem except through
locations conferred by a user selection, so every scan began with a file chooser. And it cannot see
snapshot space at all, so FR-017 could not be satisfied. Constitution v2.0.0 removed the sandbox
requirement and closed the distribution question in favour of direct download, which resolves all
three.

**Consequences worth stating plainly**: Full Disk Access cannot be requested programmatically. The
user grants it in System Settings and the app usually needs relaunching for it to take effect,
which makes FR-018 and FR-019 genuine onboarding rather than edge cases. The app must remain useful
without it. Losing the sandbox also removes the operating system as a limit on what the app can
delete, which is why constitution v2.0.0 amended Principle II to state that the removal guards are
now the only barrier, and Principle I to enforce the no-network guarantee by inspecting the binary
rather than by declaring an entitlement.

**Alternatives considered**: Staying sandboxed was the prior decision and is documented above as
rejected. Security-scoped bookmarks are no longer required for access, though the same API remains
a reasonable way to record recent locations durably. A privileged helper tool is unnecessary now
that the main executable can read directly, and would add a large security surface for a
read-mostly utility.

---

## R2. Directory traversal API

**Decision**: Use `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`
with an explicit, minimal set of resource keys prefetched in the same call, an `errorHandler` that
records unreadable entries and returns `true` to continue, and an `autoreleasepool` around each
batch. Use `skipDescendants()` to implement user exclusions, and `.skipsPackageDescendants` during the
main pass so application bundles are measured as single items. A bundle the user chooses to open is
then enumerated on demand as a separate targeted pass and spliced into the store.

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
available capacity.

**Rationale**: These are the same figures Disk Utility surfaces; they originate from the system's
CacheDelete subsystem rather than from APFS directly, which is why they disagree with the Finder's
cached values. Available capacity already includes purgeable space, so subtracting gives the
purgeable figure without a private interface.

> **Corrected during implementation of User Story 2.** Everything below this line replaces earlier
> conclusions that were reached by reading documentation rather than by running the tools. Two of
> them were wrong, and both were load-bearing. The figures quoted are from a stock Apple silicon
> Mac running macOS 26.

### Purgeable space is not a cause of the gap

The original reconciliation was: measured, plus permission-denied locations, plus user exclusions,
plus purgeable space, plus a residual. Purgeable does not belong in that sum. It sits *inside* the
volume's used figure, and with no snapshots present it consists of caches and trash — real files
the scan already counted. Adding it double counts them.

Measured against the machine above: used is 429.06 GB and purgeable is 12.06 GB. Adding purgeable
to the causes overshoots used by roughly that amount and drives the residual negative, which is
both wrong and unpresentable.

**Decision**: purgeable annotates the used figure ("429.06 GB used, of which 12.06 GB can be
reclaimed automatically") and is not one of the itemized causes. It is still named and sized, as
FR-016 asks; it is simply not additive. FR-016 was amended to match.

### Snapshots cannot be sized at all

The earlier claim that `diskutil apfs listSnapshots` reports sizes, and that they are the same
"Private Size" Disk Utility shows, is false. The tool enumerates snapshots and reports no size
field of any kind:

```
+-- A8D7E960-D5DE-46FB-B435-F8B94D6F82C5
    Name:        com.apple.os.update-5B92CE4BA1034457…
    XID:         4983886
    Purgeable:   No
```

The `-plist` form carries the same fields — `SnapshotName`, `SnapshotUUID`, `SnapshotXID`,
`Purgeable`, `LimitingContainerShrink` — and nothing resembling a byte count. `tmutil
listlocalsnapshots` also enumerates without sizes, and the underlying `fs_snapshot_*` calls remain
behind an Apple-only entitlement.

**Decision**: enumerate snapshots via the `-plist` form, which is far more stable to parse than the
tree output, name each one, and report the size as undeterminable with the reason stated. The
FR-017 fallback is therefore not an exceptional path guarding against a future parser break — it is
the only path, taken on every scan. The bytes fall through to the unattributed remainder carrying
the reason with them.

### Sibling volumes in the same container are the dominant cause

Not anticipated at all, and larger than everything else combined. An APFS container holds several
volumes sharing one pool of free space, and a scan can only walk two of them: the sealed System
volume and the Data volume that firmlinks stitch into it. On the machine above:

| Volume | Role | In use | Reachable by a scan of `/` |
| --- | --- | --- | --- |
| disk3s1 | System | 12.56 GB | yes |
| disk3s5 | Data | 383.12 GB | yes, via firmlinks |
| disk3s2 | Preboot | 8.99 GB | no |
| disk3s7 | (none) | 14.76 GB | no |
| disk3s3 | Recovery | 1.30 GB | no |
| disk3s4 | Update | 0.01 GB | no |
| disk3s6 | VM | 0.00 GB | no |

The unreachable volumes hold 25.06 GB, or 5.95% of used space — six times the budget SC-007 allows
for the unexplained remainder. Without naming them the reconciliation cannot pass on a stock Mac.
With them it lands at 0.05%.

**Decision**: read the container layout from `diskutil apfs list -plist` and itemize the volumes a
scan cannot reach as a cause of their own. Pair System with Data by role so the firmlinked partner
is not counted as unreachable. Where the pairing is ambiguous — two macOS installs in one container
give two Data volumes with nothing to distinguish them — report the extras as unreachable rather
than guessing. That overstates the cause, which surfaces as an overlap the accounting flags, rather
than understating it, which would present a wrong total confidently.

**One interface for the tool**: both readings go through a single `DiskUtilityRunning` seam that
returns raw bytes, as the constitution's platform constraints require. Parsing happens above it, so
each parser can be tested against captured output without running anything.

**A caveat to carry into the interface**: a snapshot's size, were it ever obtainable, would not be
a fixed property. Snapshots share blocks with the live filesystem, so the space unique to one grows
as the live volume diverges from it. Any future number here is a current estimate, not a fact about
the snapshot.

**Alternatives considered**: relaxing FR-017 to a residual only was the plan while the sandbox
stood. It is now closer to what actually happens for snapshots, but naming them still matters —
SC-008 requires the reason, and "there is a snapshot and macOS will not say how big it is" is a
better answer than an unexplained 8 GB.

---

## R5. Where scan results live

**Decision, revised after measurement**: SwiftData holds the durable records only — exclusion
rules, recent locations, removal history, and preferences. Scan results are the value tree the
engine already produces, held for the length of the session and rendered directly.

**The measurement that changed it.** SwiftData was chosen first, without a benchmark, on the
grounds that following Principle V's default needs no justification. It proved to be the dominant
cost. On a 50,502-node fixture:

| Stage | Time |
|---|---|
| Traversal, before parallelism | 0.81 s |
| Traversal, parallel | 0.39 s |
| Model import, inline on the main actor | 1.83 s |
| Model import, via a background `@ModelActor` | 5.86 s |

Materialising one model object per file cost between 4.7 and 15 times the price of reading the
entire tree. Inline import froze the interface for its whole duration; moving it to a background
actor unfroze the interface but tripled total time because of the save. Extrapolated to the
500,000 items in SC-001, the import alone lands between 18 and 59 seconds against a 60 second
budget for the whole scan.

Removing it entirely takes a 50,000-node scan from roughly 6.2 seconds to 0.39, and deletes a
layer of code rather than adding one. Principle V permits exactly this on exactly this evidence.

**Superseded approach**: one container with two configurations, scan data in-memory-only. That
kept a full index of the user's disk out of Application Support, which mattered; holding the tree
in memory achieves the same thing more directly.

**Rationale**: the risk anticipated here — that a million managed objects would miss the
performance targets — materialised at a twentieth of that scale, and the numbers above are what
reopened the decision. Building the simple thing first was still the right order: it produced the
evidence in an afternoon rather than an argument.

**Still available if the value tree proves insufficient.** An integer-indexed store using parallel
arrays would cut per-node overhead to tens of bytes and make aggregation cache-friendly. A
memory-mapped file of that same layout under `~/Library/Caches` was the strongest option on the
merits — near-memory access speed, the kernel's page cache handling memory pressure, and
persistence essentially free, which would also have made comparison between scans cheap — but it
carries the same custom-format maintenance cost. Both remain available if SwiftData proves
inadequate; the mmap route in particular is the natural next step rather than a rewrite, since the
node layout it needs is straightforward to produce.

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

**Discovered during implementation**: the project carries `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, which is the Xcode 26 default for a new app. Every type is main-actor isolated unless
it says otherwise, so satisfying Principle III is not a matter of avoiding `@MainActor` — it
requires marking scanning, analysis, and layout types `nonisolated` explicitly. Anything intended
to run off the main actor and declared without that annotation will compile as main-actor isolated
and quietly defeat the principle. Every type in `Scanning/` is annotated accordingly, and new
background work must do the same.

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

**Rationale**: All three are platform capabilities requiring no entitlement and no dependency.
Quick Look
generates previews out of process, so a malformed file cannot take the app down with it, which
matters when previewing arbitrary content found on someone's disk.

---

## R12. Summary of decisions requiring follow-up

| Item | Follow-up required |
|---|---|
| R1 access model | Closed. Constitution v2.0.0 dropped the sandbox; build settings updated to match |
| R4 snapshot sizing | Closed. FR-017 amended with a fallback to the residual when sizing fails |
| R5 scan storage | Closed by measurement. Value tree for scan results, SwiftData for durable records; benchmark recorded above |
| R8 Swift 6 mode | Closed. `SWIFT_VERSION` is 6.0, and the isolation default noted above made `nonisolated` an explicit requirement rather than a formality |
