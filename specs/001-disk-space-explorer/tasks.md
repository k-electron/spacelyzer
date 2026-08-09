---

description: "Task list for Disk Space Explorer implementation"
---

# Tasks: Disk Space Explorer

**Input**: Design documents from `/specs/001-disk-space-explorer/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: Test tasks are included because Principle IV requires them — every change lands with
both suites passing, and deletion guards must carry automated coverage. Note that the constitution
explicitly does **not** mandate TDD: "Tests may be written before or after the implementation they
cover; what is enforced is coverage at merge time, not authoring order." Test tasks are therefore
listed alongside implementation within each story rather than as a gate before it.

**Organization**: Tasks are grouped by user story so each can be implemented, tested, and demoed
independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US8)
- Exact file paths are included in every task

## Path Conventions

Single macOS app target. Source under `Spacelyzer/`, grouped by capability rather than by layer, as
decided in plan.md. Tests under `SpacelyzerTests/` and `SpacelyzerUITests/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Clear the template scaffolding and establish the project skeleton

- [X] T001 Delete the Xcode template model at `Spacelyzer/Item.swift`
- [X] T002 Replace the placeholder list in `Spacelyzer/ContentView.swift` with an empty root view
- [X] T003 [P] Create the capability folders `Access/`, `Scanning/`, `Accounting/`, `Analysis/`, `Treemap/`, `Cleanup/`, `Models/`, `Views/`, `Support/` under `Spacelyzer/`
- [X] T004 Set `SWIFT_VERSION` to 6.0 for all targets in `Spacelyzer.xcodeproj/project.pbxproj` and resolve any strict-concurrency errors that surface
- [X] T005 [P] Grant the UI test runner automation permission so `xcodebuild test` can start, per the prerequisite in `specs/001-disk-space-explorer/quickstart.md` (environment task, blocks merge gate 2)
- [X] T006 [P] Create the temporary-directory fixture builder in `SpacelyzerTests/Fixtures/FixtureTree.swift` supporting known sizes, hard links, symlinks, unreadable directories, and generated trees of arbitrary node count

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Models, storage configuration, and cross-cutting support every story depends on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T007 Define the scan node as the `ScannedItem` value type in `Spacelyzer/Scanning/ScanEngine.swift` with children, name, kind, category, ownSize, cumulativeSize, itemCount, dates, and flags per data-model.md
- [X] T008 [P] Create the scan state machine in `Spacelyzer/Models/ScanTypes.swift` covering idle, requestingAccess, scanning, completed, cancelled, and stale
- [X] T009 [P] Create the durable models `ExclusionRule`, `RecentLocation`, and `Preferences` in `Spacelyzer/Models/DurableRecords.swift`
- [X] T010 [P] Create `RemovalHistoryEntry` and `RemovedItemRecord` in `Spacelyzer/Models/RemovalHistory.swift`
- [X] T011 Configure the `ModelContainer` in `Spacelyzer/SpacelyzerApp.swift` for the durable records; scan results are held as a value tree rather than in SwiftData, per the benchmark recorded in research R5
- [X] T012 [P] Add OSLog loggers in `Spacelyzer/Support/Logging.swift` with file paths and user content marked private (Principle I)
- [X] T013 [P] Add the size formatter in `Spacelyzer/Support/SizeFormatter.swift` supporting decimal and binary conventions driven by `Preferences` (FR-020, FR-021)
- [X] T014 [P] Add file category derivation from `UTType` in `Spacelyzer/Support/Category.swift`
- [X] T015 Add the delay-then-show activity primitive in `Spacelyzer/Support/ActivityIndicator.swift` that reveals progress only once an operation passes roughly 150 ms (FR-069, Principle III)
- [X] T016 [P] Add the shared split-view container in `Spacelyzer/Views/MainSplitView.swift` with an adjustable divider, hierarchy leading and treemap trailing (FR-026)
- [X] T017 [P] Unit test the size formatter across both unit conventions in `SpacelyzerTests/SizeFormatterTests.swift`
- [X] T018 [P] Unit test the delay-then-show primitive, asserting no indicator for fast operations, in `SpacelyzerTests/ActivityIndicatorTests.swift`

**Checkpoint**: Models, storage, and cross-cutting support ready — user stories can begin

---

## Phase 3: User Story 1 - Find out where the space went (Priority: P1) 🎯 MVP

**Goal**: Choose a folder or volume, watch it being measured, and browse the result as an
expandable hierarchy ordered largest first.

**Independent Test**: Scan a fixture with a known arrangement and confirm sizes, ordering, and
drill-down to individual files all match; cancel a large scan and confirm it stops within a second
with partial results retained.

### Tests for User Story 1

- [X] T019 [P] [US1] Test traversal correctness against a known fixture tree in `SpacelyzerTests/ScanEngineTests.swift`
- [X] T020 [P] [US1] Test that hard-linked data is counted once while appearing at every path in `SpacelyzerTests/ByteAccountingTests.swift`
- [X] T021 [P] [US1] Test that a symlink to an ancestor neither loops nor inflates totals in `SpacelyzerTests/ByteAccountingTests.swift`
- [X] T022 [P] [US1] Test that unreadable directories are skipped and reported rather than aborting the scan in `SpacelyzerTests/ScanEngineTests.swift`
- [X] T023 [P] [US1] Test that cancellation takes effect within one second and retains partial results in `SpacelyzerTests/ScanCancellationTests.swift`
- [X] T024 [P] [US1] Test that every folder reports both its own and its cumulative size in `SpacelyzerTests/ScanEngineTests.swift`

### Implementation for User Story 1

- [X] T025 [US1] Define the `FileSystemProvider` seam in `Spacelyzer/Scanning/FileSystemProvider.swift` so traversal can be tested against fixtures without touching a real home directory
- [X] T026 [US1] Implement volume enumeration and the folder chooser in `Spacelyzer/Access/AccessBroker.swift` (FR-001)
- [X] T027 [US1] Implement `ScanEngine` traversal in `Spacelyzer/Scanning/ScanEngine.swift` using `FileManager.enumerator` with prefetched resource keys, an error handler that continues, and an autoreleasepool per batch (research R2)
- [X] T028 [US1] Implement allocated-size accounting and hard-link deduplication by volume and file identifier in `Spacelyzer/Scanning/ScanEngine.swift` and `Spacelyzer/Scanning/FileSystemProvider.swift` (FR-006, research R3) — kept alongside traversal rather than in a separate `ByteAccounting.swift`, since the identity set is scan-scoped state that only the walk uses
- [X] T029 [US1] Skip package contents during the main pass and implement `expandPackage` for on-demand bundle measurement in `Spacelyzer/Scanning/ScanEngine.swift` (FR-022)
- [X] T030 [US1] Implement the cumulative size and item-count rollup in `Spacelyzer/Scanning/ScanEngine.swift` (FR-008)
- [X] T031 [US1] Emit coalesced progress events and check cancellation at every directory batch boundary in `Spacelyzer/Scanning/ScanEngine.swift` (FR-003, FR-004)
- [X] T032 [US1] Build the hierarchy outline view in `Spacelyzer/Views/HierarchyOutlineView.swift` showing name, cumulative size, share of parent, and item count (FR-023)
- [X] T033 [US1] Add largest-first default ordering plus sorting by name, size, item count, and date modified in `Spacelyzer/Views/HierarchyOutlineView.swift` (FR-024)
- [X] T034 [US1] Add full keyboard navigation for expand, collapse, and traversal in `Spacelyzer/Views/HierarchyOutlineView.swift` (FR-025)
- [X] T035 [US1] Build the scan progress and cancellation UI in `Spacelyzer/Views/ScanProgressView.swift` (FR-003, FR-004)
- [X] T036 [US1] Implement recent locations and rescan in `Spacelyzer/Access/RecentLocations.swift` (FR-009)
- [X] T037 [US1] Present skipped locations with their reasons in `Spacelyzer/Views/SkippedLocationsView.swift` (FR-005)

**Checkpoint**: A usable disk analyzer — scan, browse, cancel, rescan

---

## Phase 4: User Story 2 - Trust the totals (Priority: P2)

**Goal**: Reconcile the measured total against what the volume reports, itemizing every cause of
the difference so no gap is ever unexplained.

**Independent Test**: Scan a volume with known snapshot usage, an unreadable folder, and a
deliberate exclusion; confirm measured plus itemized causes reconciles within 1% and each cause is
named with its own size.

### Tests for User Story 2

- [X] T038 [P] [US2] Test that measured plus every unaccounted entry reconciles to volume used within 1% in `SpacelyzerTests/VolumeAccountantTests.swift` (SC-007)
- [X] T039 [P] [US2] Test that an unattributable remainder is always named and sized, never omitted or zeroed, in `SpacelyzerTests/VolumeAccountantTests.swift` (SC-008)
- [X] T040 [P] [US2] Test that a snapshot sizing failure falls through to the residual with its reason stated in `SpacelyzerTests/SnapshotReaderTests.swift` (FR-017)
- [X] T041 [P] [US2] Test that an excluded folder is reported distinctly from a permission-denied one in `SpacelyzerTests/ExclusionTests.swift` (FR-012)
- [X] T042 [P] [US2] Test that excluding the scan root is refused in `SpacelyzerTests/ExclusionTests.swift` (FR-012)

### Implementation for User Story 2

- [X] T043 [US2] Implement `VolumeAccountant` in `Spacelyzer/Accounting/VolumeAccountant.swift` reading total capacity, available capacity, and available-for-important-usage, deriving purgeable space from the difference (research R4)
- [X] T044 [US2] Implement snapshot reading behind a single interface in `Spacelyzer/Accounting/SnapshotReader.swift`, invoking `diskutil apfs listSnapshots -plist`, treating its output as untrusted, and degrading to the residual on any parse failure (FR-017) — the task said "sizing", which turned out to be impossible: the tool reports no size field at all, so the degrade path is the only path. Research R4 records the corrected finding.
- [X] T045 [US2] Implement unaccounted-space itemization covering permission denied, user excluded, other volumes, snapshots, the unscanned rest of a volume, and unattributed in `Spacelyzer/Accounting/UnaccountedSpace.swift` (FR-016) — purgeable was dropped from the itemization and moved to an annotation on used space per FR-017a, and two causes the original list did not anticipate were added
- [X] T046 [US2] Implement Full Disk Access state detection and the System Settings deep link in `Spacelyzer/Access/AccessBroker.swift` (FR-018)
- [X] T047 [US2] Detect a later access grant and offer a rescan in `Spacelyzer/Access/AccessBroker.swift` (FR-019)
- [X] T048 [US2] Warn before results are shown, naming each protected location that will be missing, in `Spacelyzer/Views/AccessWarningView.swift` (FR-018)
- [X] T049 [US2] Implement exclusion rule management with persistence, root-exclusion refusal, and marking existing scans stale in `Spacelyzer/Access/ExclusionRules.swift` (FR-010 through FR-013)
- [X] T050 [US2] Build the accounting panel in `Spacelyzer/Views/VolumeAccountingView.swift` showing capacity, used, free, measured, and each itemized cause with a plain-language explanation (FR-014 through FR-017)
- [X] T050a [US2] Read the APFS container layout in `Spacelyzer/Accounting/ContainerReader.swift` so volumes sharing the drive can be named (FR-016) — not in the original breakdown; without it the unexplained remainder is 5.95% on a stock Mac and SC-007 cannot pass
- [X] T050b [US2] Isolate every `diskutil` invocation behind one seam in `Spacelyzer/Accounting/DiskUtility.swift`, as the constitution's platform constraints require, with parsing above it so it can be tested against captured output
- [X] T050c [US2] Build the exclusion list editor in `Spacelyzer/Views/ExclusionsSheet.swift` — not in the original breakdown, and FR-010 and FR-011 cannot be met without it, since T049 delivers only the model layer

**Checkpoint**: The numbers add up and the user can see why

---

## Phase 5: User Story 3 - See the shape of the disk at a glance (Priority: P3)

**Goal**: A proportional treemap where the things worth attention are obvious without reading a
number.

**Independent Test**: Scan a fixture whose dominant file is roughly half the total and confirm its
rectangle occupies roughly half the area, with colors distinguishing categories and hover revealing
path and size.

### Tests for User Story 3

- [X] T051 [P] [US3] Test that rectangle areas are proportional to cumulative size share in `SpacelyzerTests/TreemapLayoutTests.swift` (FR-027)
- [X] T052 [P] [US3] Test that every child rectangle lies entirely within its parent's bounds in `SpacelyzerTests/TreemapLayoutTests.swift` (FR-028)
- [X] T053 [P] [US3] Test that identical input produces an identical layout so rectangles never reshuffle in `SpacelyzerTests/TreemapLayoutTests.swift` (research R6)
- [X] T054 [P] [US3] Test that undrawable siblings are combined into a remainder node rather than dropped in `SpacelyzerTests/TreemapLayoutTests.swift` (FR-032)

### Implementation for User Story 3

- [X] T055 [US3] Implement the squarified layout algorithm in `Spacelyzer/Treemap/SquarifiedLayout.swift` as a pure function, ordering siblings by descending size with a name tie-break — the contract's signature gained a `rootPath` parameter, since `ScannedItem` stores names only and FR-030 needs full paths on hover
- [X] T056 [US3] Synthesise remainder nodes for siblings below the minimum drawable area in `Spacelyzer/Treemap/SquarifiedLayout.swift` (FR-032)
- [X] T057 [US3] Run layout off the main actor and deliver it as an immutable snapshot, superseding any in-flight layout on resize or drill, in `Spacelyzer/Treemap/LayoutCoordinator.swift` (Principle III) — the snapshot carries the spatial index too, because indexing a large layout on the main actor would undo the point of computing it off one
- [X] T058 [US3] Render the treemap through a single SwiftUI `Canvas` drawing pre-computed rectangles in `Spacelyzer/Treemap/TreemapCanvas.swift`
- [X] T059 [US3] Draw a visible boundary around each item so nesting is readable in `Spacelyzer/Treemap/TreemapCanvas.swift` (FR-028)
- [X] T060 [US3] Apply category colors and build the legend in `Spacelyzer/Views/TreemapLegendView.swift` (FR-029)
- [X] T061 [US3] Build the spatial index for hit testing and hover in `Spacelyzer/Treemap/SpatialIndex.swift` (SC-005)
- [X] T062 [US3] Reveal path and size on hover without a click in `Spacelyzer/Treemap/TreemapCanvas.swift` (FR-030)
- [X] T063 [US3] Implement drill-in and navigate-out, keeping the previous layout visible while the new one computes, in `Spacelyzer/Treemap/LayoutCoordinator.swift` (FR-031)
- [X] T063a [US3] Add the drill trail in `Spacelyzer/Views/TreemapLegendView.swift` so navigating out is one click from any depth (FR-031), and a Treemap/Totals selector in `Spacelyzer/Views/MainSplitView.swift` so the accounting panel from US2 keeps a home now that the trailing pane belongs to the treemap (FR-026)

**Checkpoint**: The scan is legible at a glance

---

## Phase 6: User Story 4 - Move between the picture and the list (Priority: P4)

**Goal**: One selection shared by both views, navigable in either direction, and reachable by
VoiceOver.

**Independent Test**: Select a deeply nested item in the outline and confirm its treemap region
highlights; click a different region and confirm the outline expands, selects, and scrolls to it.

### Tests for User Story 4

- [X] T064 [P] [US4] Test that selecting in the outline highlights the matching treemap region in `SpacelyzerTests/SelectionCoordinatorTests.swift` (FR-033)
- [X] T065 [P] [US4] Test that selecting in the treemap expands ancestors and selects the outline row in `SpacelyzerTests/SelectionCoordinatorTests.swift` (FR-034)
- [X] T066 [P] [US4] Test that a selection outside the drilled root resolves to a defined state rather than disagreeing in `SpacelyzerTests/SelectionCoordinatorTests.swift` (FR-036)

### Implementation for User Story 4

- [X] T067 [US4] Implement `SelectionCoordinator` holding exactly one selection shared by both views in `Spacelyzer/Views/SelectionCoordinator.swift` (FR-035) — identified by path rather than by `ScannedItem`, which is a value with no identity and would make two matching files indistinguishable
- [X] T068 [US4] Highlight the selection at draw time without triggering relayout in `Spacelyzer/Treemap/TreemapCanvas.swift` (SC-004) — the layout snapshot gained a path index so the highlight is a lookup rather than a scan of every rectangle per draw
- [X] T069 [US4] Expand ancestors, select, and scroll into view on treemap-originated selection in `Spacelyzer/Views/HierarchyOutlineView.swift` (FR-034)
- [X] T070 [US4] Resolve selection to the nearest containing ancestor when the drilled root excludes it in `Spacelyzer/Views/SelectionCoordinator.swift` (FR-036)
- [X] T071 [US4] Expose drawn treemap nodes as accessibility elements labelled with name, size, and share, driving the shared selection, in `Spacelyzer/Treemap/TreemapCanvas.swift` (research R7, Principle V) — capped at the hundred largest regions, since a layout can hold tens of thousands and the outline is the complete equivalent
- [X] T072 [US4] Add a VoiceOver UI test covering outline navigation and treemap element announcement in `SpacelyzerUITests/AccessibilityTests.swift` — which caught a real defect: file rows were announcing their own truncated text with no size, because combining children let the drawn label through

**Checkpoint**: The two views behave as one tool, and the treemap is navigable without sight

---

## Phase 7: User Story 5 - Narrow down to what actually matters (Priority: P5)

**Goal**: Ask pointed questions of the result and see what kind of thing is filling the disk.

**Independent Test**: Apply a minimum size filter to a mixed fixture and confirm both views show
exactly the matching subset with a correct count and total; open the category breakdown and confirm
its totals reconcile.

### Tests for User Story 5

- [X] T073 [P] [US5] Test name, category, extension, size, and date filters individually in `SpacelyzerTests/FilterEvaluatorTests.swift` (FR-037 through FR-040)
- [X] T074 [P] [US5] Test that combined filters intersect and that match count and total size are correct in `SpacelyzerTests/FilterEvaluatorTests.swift` (FR-041, FR-043)
- [X] T075 [P] [US5] Test that a directory is retained for structure when a descendant matches in `SpacelyzerTests/FilterEvaluatorTests.swift`
- [X] T076 [P] [US5] Test that category totals reconcile with the scan and rank by size in `SpacelyzerTests/CategoryAnalyzerTests.swift` (FR-044) — the suite lives alongside the filter tests, since most of what is worth asserting is that the two agree

### Implementation for User Story 5

- [X] T077 [US5] Define the `Filter` value type in `Spacelyzer/Models/Filter.swift` covering name, categories, extensions, size range, and modified range
- [X] T078 [US5] Implement `FilterEvaluator` producing a set of matching identifiers with count and total in `Spacelyzer/Analysis/FilterEvaluator.swift` (FR-043) — the result also carries the folders retained for structure, which the contract describes but did not name
- [X] T079 [US5] Run evaluation off the main actor, superseding in-flight evaluations when the filter changes, in `Spacelyzer/Analysis/FilterCoordinator.swift` (Principle III)
- [X] T080 [US5] Apply the single filter result to both views simultaneously in `Spacelyzer/Views/MainSplitView.swift` (FR-042) — the treemap lays out over the retained subset rather than dimming what is filtered out, so its areas stay proportional to what is being shown
- [X] T081 [US5] Build the filter bar with visible active filters and a single clear action in `Spacelyzer/Views/FilterBarView.swift` (FR-041)
- [X] T082 [US5] Implement `CategoryAnalyzer` producing size-ranked category totals in `Spacelyzer/Analysis/CategoryAnalyzer.swift` (FR-044)
- [X] T083 [US5] Build the category breakdown view with select-to-filter in `Spacelyzer/Views/CategoryBreakdownView.swift` (FR-044)
- [X] T084 [US5] Add the empty state explaining a filter that matches nothing, with a clear action in `Spacelyzer/Views/FilterBarView.swift` — kept beside the bar that causes it rather than in a file of its own

**Checkpoint**: A large scan becomes actionable

---

## Phase 8: User Story 6 - Look at something before acting on it (Priority: P6)

**Goal**: See what a file actually is, without leaving the app or losing your place.

**Independent Test**: Select a known image and a known document, confirm each previews inside the
app, that reveal opens the right folder, and that the reported path, sizes, and dates match.

### Tests for User Story 6

- [X] T085 [P] [US6] Test that details report the correct path, allocated size, logical size, kind, and all three dates in `SpacelyzerTests/ItemInspectorTests.swift` (FR-048) — plus a folder case, where the occupied figure covers the subtree and there is no logical length to set against it
- [X] T086 [P] [US6] Test that a file with no available preview yields an explained unavailable state rather than an error in `SpacelyzerTests/ItemInspectorTests.swift` (FR-050) — folders, empty files, symlinks, missing and unreadable items, with application bundles pinned as previewable
- [X] T087 [P] [US6] Test that inspection leaves the item's contents and location unchanged in `SpacelyzerTests/ItemInspectorTests.swift` (FR-049)

### Implementation for User Story 6

- [X] T088 [US6] Implement `ItemInspector` details, reading logical length on demand for the selected item only, in `Spacelyzer/Views/ItemInspector.swift` (FR-048) — one read answers both the details and whether there is a preview, so the two cannot describe different items
- [X] T089 [US6] Bridge `QLPreviewView` into SwiftUI in `Spacelyzer/Views/QuickLookPreview.swift` (research R11)
- [X] T090 [US6] Add the loading state and discard previews for a deselected item in `Spacelyzer/Views/ItemInspector.swift` (FR-045, Principle III)
- [X] T091 [US6] Implement reveal in Finder and open in default application in `Spacelyzer/Views/ItemInspector.swift` (FR-046, FR-047)
- [X] T092 [US6] Build the details panel showing both size figures side by side when they differ in `Spacelyzer/Views/ItemDetailsView.swift` (FR-048)
- [X] T092a [US6] Present the panel as an inspector column beside both views, closed until asked for and closed again when an analysis starts, with a UI test in `SpacelyzerUITests/SpacelyzerUITests.swift` — deciding what a large file is means seeing it and its place in the scan at once, so it could not displace either view
- [X] T092b [US6] Keep the selection watched inside the details pane rather than in `MainSplitView`, walk the tree off the main actor, and let the preview settle before Quick Look is asked — reading the selection at the top of the window made every click rebuild both panes, the legend, and an exclusion fetch
- [X] T092c [US6] Coalesce treemap resizes and stretch the drawn layout until the new one lands in `Spacelyzer/Treemap/LayoutCoordinator.swift` and `TreemapCanvas.swift` — squarifying has no cancellation point, so a moving pane had a dozen full layouts running at once
- [X] T092d [US6] Move the window to `NavigationSplitView` and keep the stretched treemap out of the layout, with a measured regression test in `SpacelyzerUITests/SpacelyzerUITests.swift` — `HSplitView` ignored both panes' ideal widths and split the window in half, and the stretched canvas had been given a fixed frame that stopped the treemap shrinking, so the details panel opened on top of it

**Checkpoint**: Nothing gets deleted sight-unseen

---

## Phase 9: User Story 7 - Reclaim space without losing anything (Priority: P7)

**Goal**: Remove what the user chose, reversibly, with every guard enforced below the interface.

**Independent Test**: Select known throwaway files, confirm the dialog reports the correct count
and reclaimable total, complete the removal, verify recoverability from the Trash, then undo and
confirm the files return to their original locations.

### Tests for User Story 7

- [X] T093 [P] [US7] Test that protected system locations and the app's own container are refused in `SpacelyzerTests/RemovalGuardTests.swift` (FR-055, Principle II) — plus roots, the home folder, the folders the system expects, and that their contents stay removable
- [X] T094 [P] [US7] Test that producing a removal plan has no side effects in `SpacelyzerTests/RemovalGuardTests.swift`
- [X] T095 [P] [US7] Test that refusing some candidates still permits the remainder in `SpacelyzerTests/RemovalGuardTests.swift` (FR-055)
- [X] T096 [P] [US7] Test that removal defaults to the Trash and captures each resulting Trash URL in `SpacelyzerTests/RemovalServiceTests.swift` (FR-053)
- [X] T097 [P] [US7] Test that a per-item failure does not abort the batch and appears in the summary in `SpacelyzerTests/RemovalServiceTests.swift` (FR-056)
- [X] T098 [P] [US7] Test that undo restores every item when they remain in the Trash in `SpacelyzerTests/UndoServiceTests.swift` (SC-014)
- [X] T099 [P] [US7] Test that an impossible undo reports its specific reason and never claims success in `SpacelyzerTests/UndoServiceTests.swift` (FR-060) — emptied Trash, missing folder, occupied location, and a partial restoration that must not read as a whole one
- [X] T100 [P] [US7] Add a UI test covering select, confirm, remove, and undo in `SpacelyzerUITests/RemovalFlowTests.swift` — reads the confirmation before agreeing to it, so an app proposing anything but the test's own fixture fails the test rather than deleting

### Implementation for User Story 7

- [X] T101 [US7] Implement `RemovalGuard` producing an inert `RemovalPlan`, evaluated before the confirmation appears, in `Spacelyzer/Cleanup/RemovalGuard.swift` (FR-055)
- [X] T102 [US7] Determine Trash availability for the target volume up front in `Spacelyzer/Cleanup/RemovalGuard.swift` (FR-053) — all of the selection rather than any of it, since the user is about to be told the whole removal is recoverable
- [X] T103 [US7] Implement `RemovalService` accepting only a plan, trashing items and capturing resulting Trash URLs, in `Spacelyzer/Cleanup/RemovalService.swift` (FR-051 through FR-053) — and re-checking each item against the guard on its way out, because a plan is a value and a value can be built by anyone
- [X] T104 [US7] Stream per-item removal events, continue past failures, and always emit a finished summary in `Spacelyzer/Cleanup/RemovalService.swift` (FR-056)
- [X] T105 [US7] Build the confirmation dialog listing affected items, count, and reclaimable total in `Spacelyzer/Views/RemovalConfirmationView.swift` (FR-052)
- [X] T106 [US7] Add permanent deletion as a separate explicit choice with an irreversibility warning in `Spacelyzer/Views/RemovalConfirmationView.swift` (FR-054)
- [X] T107 [US7] Keep the interface interactive and the cancel control reachable during removal in `Spacelyzer/Views/RemovalConfirmationView.swift` (FR-071, Principle III) — kept beside the progress it belongs to rather than in a file of its own
- [X] T108 [US7] Update both views to reflect reclaimed space without a rescan in `Spacelyzer/Scanning/ScanController.swift` (FR-057) — prunes only the path down to what went, and keeps the pruned subtrees so an undo can graft them back rather than costing a fresh walk of the disk
- [X] T109 [US7] Implement `UndoService` streaming per-item restoration events in `Spacelyzer/Cleanup/UndoService.swift` (FR-059, FR-070)
- [X] T110 [US7] Report undo availability before offering the action, distinguishing emptied Trash, missing original location, and permanent deletion, in `Spacelyzer/Cleanup/UndoService.swift` (FR-060)
- [X] T111 [US7] Persist removal history and build the reviewable, clearable history view in `Spacelyzer/Views/RemovalHistoryView.swift` (FR-061)
- [ ] T111a [US7] Extend the shared selection to more than one item so a removal can be asked of several at once (FR-051) — the batch machinery takes any number and a folder already stands for many files, but the selection itself still holds one path, which is a gap against the requirement rather than a decision

**Checkpoint**: Space can be reclaimed safely and reversibly

---

## Phase 10: User Story 8 - Find the same file stored several times (Priority: P8)

**Goal**: Group byte-identical files by recoverable space, never allowing the last copy to be
deleted.

**Independent Test**: Place byte-identical files under different names in different folders and
confirm they group as one set with the correct recoverable total; confirm equal-sized files with
differing contents do not group.

### Tests for User Story 8

- [ ] T112 [P] [US8] Test that byte-identical files group into one set with the correct recoverable total in `SpacelyzerTests/DuplicateFinderTests.swift` (FR-062, FR-064)
- [ ] T113 [P] [US8] Test that equal-sized files with differing contents are never reported as duplicates in `SpacelyzerTests/DuplicateFinderTests.swift` (FR-063)
- [ ] T114 [P] [US8] Test that a selection removing every copy in a set is refused by the set itself in `SpacelyzerTests/DuplicateFinderTests.swift` (FR-065)
- [ ] T115 [P] [US8] Test that the size threshold excludes files below it and is adjustable in `SpacelyzerTests/DuplicateFinderTests.swift`

### Implementation for User Story 8

- [ ] T116 [US8] Implement the three-stage duplicate search — group by size, compare a bounded prefix hash, then full streamed SHA-256 — in `Spacelyzer/Analysis/DuplicateFinder.swift` (research R9)
- [ ] T117 [US8] Apply the 1 MB default size threshold from `Preferences`, adjustable down to zero, in `Spacelyzer/Analysis/DuplicateFinder.swift`
- [ ] T118 [US8] Report per-stage progress and check cancellation between files in `Spacelyzer/Analysis/DuplicateFinder.swift` (FR-066)
- [ ] T119 [US8] Enforce keep-one on `DuplicateSet` itself rather than in the view in `Spacelyzer/Models/DuplicateSet.swift` (FR-065)
- [ ] T120 [US8] Build the duplicates view ranked by recoverable space in `Spacelyzer/Views/DuplicatesView.swift` (FR-064)

**Checkpoint**: All eight stories independently functional

---

## Phase 11: Polish & Cross-Cutting Concerns

- [X] T121 [P] Verify no `print` calls remain and that captured logs redact paths, across `Spacelyzer/` — none remain, nor `NSLog`, `debugPrint`, or `dump`. The redaction half turned out to be vacuous: the app builds no `Logger` and calls no `os_log` anywhere, so there is no captured log to redact a path from. The one place a path could still reach a crash report is the `fatalError` in `SpacelyzerApp.swift`, which interpolates a SwiftData error carrying the store URL — the app's own container rather than anything scanned. Recorded below as an open question, since what is wrong with that line is the crash rather than the path
- [ ] T122 [P] Full VoiceOver pass over every view, confirming keyboard reachability of all treemap operations (Principle V)
- [ ] T123 Measure a 500,000-item fixture scan against SC-001 and SC-002 and record the result in `specs/001-disk-space-explorer/research.md` R5
- [ ] T124 Measure filter application and treemap interaction at 1,000,000 items against SC-005 and SC-009, and reopen the storage decision in research R5 if either is missed
- [X] T125 [P] Confirm no operation leaves the interface unchanged beyond 150 ms without indication, per SC-017 — pinned as a test in `SpacelyzerTests/SupportTests.swift` rather than confirmed by watching, so a coordinator added later with a slacker threshold fails the build. Scanning, reconciling the volume, filtering, and laying out the treemap all reveal at exactly 150 ms; removal and undo show progress immediately, having no threshold to meet. Inspection is the one deliberate exception at 300 ms, because Quick Look is not asked for anything until the selection has held still for 150 ms and an indicator on the same threshold would appear and vanish on every click. The click is still answered inside the budget by the selection moving in both views and the facts landing, so what waits is the spinner over the preview rather than the window's response
- [ ] T126 [P] Observe network activity across a full session to confirm SC-016 holds
- [X] T127 Work through every scenario in `specs/001-disk-space-explorer/quickstart.md` and correct any that no longer match behaviour (Principle VII) — the pre-implementation storage gate had long since closed and still read as pending; the details panel now starts closed, so scenario 6 says where its button is; scenario 7 asked for several files to be selected, which is the T111a gap rather than something a reader can do; the privacy check asked for redaction of logs that do not exist; and the toolchain note described one machine's state as though it were everyone's
- [X] T128 [P] Update `specs/001-disk-space-explorer/spec.md` and `plan.md` for any divergence discovered during implementation (Principle VII) — the plan had Swift 5.0 as a current fact and Swift 6 as pending work, listed OSLog among the dependencies, and claimed under Principle I that logging marks paths private, none of which was true. Two passages still argued for SwiftData holding scan results, contradicting the gate item above them that records the reversal; both now carry the prediction and its correction rather than a tidied-up version of only the second. `spec.md` needed no change: where it and the code disagree, on selecting more than one item for removal, the spec is right and T111a is the work
- [ ] T129 Configure Developer ID signing and notarization for release builds in `Spacelyzer.xcodeproj/project.pbxproj`, confirming `get-task-allow` is absent from the distributed artifact
- [X] T130 Write the project README describing what Spacelyzer is and how to build it — including what the tests do to the machine they run on, since the removal cases use the real Trash
- [X] T131 Add continuous integration on GitHub's free macOS runners in `.github/workflows/ci.yml`, and commit a shared scheme so a fresh clone has one to build — the scheme had only ever existed in per-user state, which is ignored, so `xcodebuild -scheme` worked on the author's machine and nowhere else
- [ ] T132 Decide what the app does when its durable store will not open, in `Spacelyzer/SpacelyzerApp.swift` — it currently calls `fatalError`, so a corrupt store makes the app permanently unlaunchable, and nothing it holds is needed to scan a disk. Falling back to an in-memory container would keep the app usable, but silently: the history view would show an empty history and forget everything again on quit, which is a poor reading of Principle II's promise to keep a full record of removals. Worth doing properly, meaning the fallback plus a plain statement that nothing is being kept this session, rather than either half on its own. Found while verifying T121

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS every user story
- **User Stories (Phases 3–10)**: All depend on Foundational
- **Polish (Phase 11)**: Depends on the stories being delivered

### User Story Dependencies

Unlike a typical feature set, these stories are **not** all independent — the two views must exist
before they can be linked, and the guards must exist before anything is deleted.

- **US1 (P1)**: Depends only on Foundational. The MVP.
- **US2 (P2)**: Depends on US1 for a completed scan to reconcile against
- **US3 (P3)**: Depends on US1 for scan results to draw
- **US4 (P4)**: Depends on US1 and US3 — it links the two views, so both must exist
- **US5 (P5)**: Depends on US1; also touches US3 once the treemap exists
- **US6 (P6)**: Depends on US1 for a selection to inspect
- **US7 (P7)**: Depends on US1 and US6 — inspection is what makes removal safe in practice
- **US8 (P8)**: Depends on US1 and US7, reusing the guarded removal flow

### Within Each User Story

- Models before services, services before views
- Pure logic before its interface, so it can be tested without one
- Tests may be written before or after implementation; coverage is enforced at merge, not ordering

### Parallel Opportunities

- Setup tasks T003, T005, T006 run in parallel
- Foundational models T008, T009, T010 run in parallel, as do support tasks T012, T013, T014
- Every test task marked [P] within a story runs in parallel
- Once US1 lands, US2, US3, and US6 can proceed in parallel by different people
- US4 cannot start until US3 lands; US7 should not start until US6 lands

---

## Parallel Example: User Story 1

```bash
# Tests for User Story 1 can all be written in parallel:
Task: "Test traversal correctness in SpacelyzerTests/ScanEngineTests.swift"
Task: "Test hard-link counted once in SpacelyzerTests/ByteAccountingTests.swift"
Task: "Test symlink loop safety in SpacelyzerTests/ByteAccountingTests.swift"
Task: "Test unreadable directories skipped in SpacelyzerTests/ScanEngineTests.swift"
Task: "Test cancellation within one second in SpacelyzerTests/ScanCancellationTests.swift"

# Foundational models can be built in parallel:
Task: "Create Scan model in Spacelyzer/Models/Scan.swift"
Task: "Create durable records in Spacelyzer/Models/DurableRecords.swift"
Task: "Create removal history in Spacelyzer/Models/RemovalHistory.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: scan a real folder, confirm sizes, cancel a large scan
5. This alone is a usable disk analyzer worth keeping

### Incremental Delivery

1. Setup and Foundational → foundation ready
2. US1 → an analyzer that answers "where did my space go" (MVP)
3. US2 → the numbers reconcile and are believable
4. US3 → the answer becomes legible at a glance
5. US4 → the two views become one tool
6. US5 → large scans become actionable
7. US6 → files can be identified before acting
8. US7 → space can actually be reclaimed, reversibly
9. US8 → redundant copies surfaced

### Watch Point

T124 is not routine polish. It measures the performance risk accepted in research R5 when storage
settled on SwiftData without a benchmark. If filtering or treemap interaction misses its target at
a million items, the storage decision reopens, and the leading alternative is already documented in
R5: the same node layout backed by a memory-mapped file under `~/Library/Caches`. Reaching that
point is a design change, not a bug fix, so it is better discovered at T124 than by a user.

---

## Notes

- [P] marks tasks touching different files with no incomplete dependencies
- Every task names the file it changes so it can be executed without further context
- Commit after each task or logical group, keeping commits atomic per Principle VIII
- Removal and duplicate guards belong in the model layer; a guard implemented in a view is a
  Principle II violation regardless of whether it works
