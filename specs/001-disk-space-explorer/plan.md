# Implementation Plan: Disk Space Explorer

**Branch**: `main` (feature directory `001-disk-space-explorer`; no feature branch was created)
| **Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-disk-space-explorer/spec.md`

## Summary

Spacelyzer measures a user-chosen folder or volume, presents the result simultaneously as a
navigable outline and a proportional treemap bound by one shared selection, and lets the user
narrow, inspect, and safely reclaim what it finds. The technical approach is a bulk-enumerated,
cancellable, concurrent scan feeding an in-memory node store that both views read from, with
durable state limited to exclusions, recent locations, and removal history. Everything runs
locally inside the App Sandbox with no network access and no third-party dependencies.

Two research findings shape the plan. Access to the disk can only be conferred by the user
selecting a root in an open panel and persisted through a security-scoped bookmark, which means
the app can never widen its own reach or enumerate volumes on its own. And space held by local
snapshots cannot be sized from inside the sandbox, which conflicts with a requirement in the spec
and must be resolved before implementation begins.

## Technical Context

**Language/Version**: Swift, Swift 6 language mode. The project is currently configured for Swift
5.0 with approachable concurrency enabled; moving to Swift 6 is a required build-setting change
recorded in [research.md](./research.md) R8.

**Primary Dependencies**: None outside the platform SDK. SwiftUI, SwiftData, Foundation, AppKit
interop, QuickLookUI, UniformTypeIdentifiers, CryptoKit, and OSLog. Zero third-party packages are
planned, so Principle VI's license, reputation, and version obligations do not yet apply.

**Storage**: SwiftData for durable records only — exclusion rules, recent locations with their
security-scoped bookmarks, removal history, and preferences. Scan results live in an
integer-indexed in-memory node store for the session, provisionally and subject to the measurement
required in research R5.

**Testing**: Swift Testing for unit coverage of traversal, accounting, layout, filtering, duplicate
grouping, and removal guards, all exercised against temporary fixture trees. XCUITest for the
primary user flows: scan, select across both views, filter, and a guarded removal with undo.

**Target Platform**: macOS 26.5 and later, built against the macOS SDK. App Sandbox and Hardened
Runtime enabled in every configuration.

**Project Type**: Native macOS desktop application, single app target with two test targets.

**Performance Goals**: 500,000 items measured in under 60 seconds (SC-001); first partial results
within 3 seconds (SC-002); cancellation effective within 1 second (SC-003); cross-view selection
propagation within 100 ms (SC-004); treemap interaction within 100 ms at 1,000,000 items (SC-005);
filter application within 200 ms at 1,000,000 items (SC-009); category breakdown within 2 seconds
without rescanning (SC-010); preview within 1 second for files up to 100 MB (SC-011).

**Constraints**: Nothing whose cost scales with the size of a scan may run on the main actor, which
puts filtering, treemap layout, and the category breakdown off it despite their being pure
functions. Any operation still running after roughly 150 milliseconds shows that it is working, and
anything exceeding two seconds reports incremental progress. Read access is
user-conferred only, never entitlement-granted. No network access of any kind. Resident memory to
stay under 500 MB for a 1,000,000-item scan, which bounds per-node overhead and rules out one
object per file. Reported sizes are allocated size, in decimal units by default.

**Scale/Scope**: 8 prioritized user stories, 68 functional requirements, 16 success criteria.
Working set up to roughly 1,000,000 nodes per scan.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Basis |
|---|---|---|
| I. Local-First and Private by Default (NON-NEGOTIABLE) | Pass | No network entitlement is declared and no feature requires one. Logging goes through OSLog with paths marked private. Scan data, exclusions, and history never leave the machine. |
| II. Destructive Actions Are Guarded (NON-NEGOTIABLE) | Pass | Removal is explicit-selection only, previewed before it runs, routed to the Trash by default, refused for protected locations before the confirmation appears, cancellable, and reversible for the most recent batch. |
| III. Never Block, Always Show Progress | **Action required** | Traversal, hashing, filtering, layout, and removal all run off the main actor, and scan cancellation is checked at every directory batch boundary. Constitution v1.4.1 broadened this principle to every operation that loads or computes, required visible activity once work passes roughly 150 milliseconds, and forbade disabling unrelated controls; the spec does not yet demand that for removal, undo, or preview. See gate item 3. |
| IV. Verified Before Merge | Pass | Scan, accounting, layout, filter, and removal-guard logic are unit-testable against fixture trees; no test touches a real home directory. |
| V. Native and Minimal | **Conditional** | SwiftUI, SwiftData, and zero dependencies satisfy the principle, and the treemap accessibility gap is resolved by research R7. However, using anything other than SwiftData for scan results requires a recorded measurement, which does not yet exist. See Complexity Tracking. |
| VI. Dependencies Are Open, Proven, and Current | Pass | No third-party dependency is planned. If one is later proposed it must clear this principle before adoption. |
| VII. Docs and Code Stay in Sync | **Action required** | Two documents will become inaccurate during implementation: FR-017 states a requirement the sandbox cannot satisfy, and the constitution records Swift 5.0 as a project fact that this plan changes. Both must be amended in the change that creates the discrepancy. |
| VIII. Only Intended Files Are Committed | Pass | The root `.gitignore` already covers macOS, Xcode, build, and credential artifacts, and no new class of generated output is introduced. |

### Gate items that must close before implementation starts

1. **Amend FR-017** so that space held by local snapshots is not required to be reported as an
   independently sized category. Research R4 establishes that no public API exposes this from
   inside the sandbox. The replacement is a named residual for space the app cannot attribute,
   with an explanation naming its usual contributors, which preserves SC-008's promise that no gap
   is ever shown without a stated cause. Until this is amended, the spec contains a requirement
   that cannot be implemented as written.
2. **Measure before deviating from SwiftData.** Principle V permits an alternative only on recorded
   measurement. The first implementation task benchmarks a SwiftData-backed store against the
   in-memory node store on a fixture tree of at least 500,000 nodes, judged against SC-001 and
   SC-009, with the result written back into research R5. If SwiftData meets the targets, the
   constitution requires using it.

3. **Extend the spec's progress obligations.** Constitution v1.4.1 broadened Principle III from
   scanning to every operation that loads, computes, or waits, and added two rules the spec does
   not yet carry: any operation still running after roughly 150 milliseconds must show that it is
   working, and background work must never disable unrelated controls or block its own
   cancellation. The spec
   requires visible progress for scanning (FR-003) and duplicate detection (FR-066) but says
   nothing for removal, undo, or preview. Add the missing requirements alongside the FR-017
   amendment so the spec is amended once rather than twice.

None of these is an unjustified violation; each is an action with an owner and a defined closing
condition. Design proceeded to Phase 1 on that basis.

### Post-design re-check

Re-run after data-model.md, the contracts, and quickstart.md were written. No new violation
appeared, and two principles are now enforced more strongly than the pre-design check assumed.

Principle II moved from an intention to a structural guarantee. `RemovalGuard` produces a
`RemovalPlan` as an inert value with no side effects, and `RemovalService` accepts nothing else —
there is no interface that takes raw paths, so no future entry point can reach deletion without
passing the guards. The keep-one rule for duplicates is likewise enforced on `DuplicateSet` rather
than in a view. Both are exhaustively unit-testable, which is what Principle II's coverage clause
demands.

Principle V's accessibility question is now answered concretely rather than deferred. The
`SelectionCoordinator` contract makes the outline the accessible equivalent of the treemap and
requires drawn treemap nodes to be exposed as accessibility elements driving the same selection.
The single-selection rule in FR-035 became load-bearing for accessibility as a result, so an
implementation that keeps two synchronised selections would break the constitutional commitment,
not merely the spec.

Principle I survived design intact: no contract has a network-capable operation, and data-model.md
explicitly refuses to persist any scan, keeping durable storage to bookmarks, totals, and history.

One new obligation surfaced from Principle VIII. The performance scenarios need a generated fixture
of at least 500,000 entries, which must be built under the system temporary directory at test time
and never inside the workspace, or it would become a large class of generated output sitting in the
repository. The quickstart specifies this, and `.gitignore` is not sufficient protection on its own
because the fixture would otherwise be created before any ignore rule could be written for it.

Re-checked again against constitution v1.4.1, which broadened Principle III. The design changed as
a result rather than merely being re-annotated. Three contracts specified work as synchronous pure
functions whose own budgets are far too large to sit on the main actor — filtering at 200
milliseconds, the category breakdown at two seconds, and treemap layout at whatever a million
nodes costs — so all three now run off the main actor, deliver results asynchronously, and are
superseded rather than queued when newer input arrives. Undo changed from returning a single value
to streaming per-item events, because restoring a large batch can exceed two seconds. An
`ItemInspector` contract was added so that preview has an explicit loading state instead of a blank
panel indistinguishable from a file that cannot be previewed.

The three gate items above remain open. All are closed by actions scheduled ahead of
implementation, not by justification.

## Project Structure

### Documentation (this feature)

```text
specs/001-disk-space-explorer/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── scanning.md
│   ├── presentation.md
│   └── cleanup.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Created later by /speckit-tasks
```

### Source Code (repository root)

```text
Spacelyzer/
├── SpacelyzerApp.swift          # App entry point and model container
├── Access/                      # Open panel, security-scoped bookmarks, access lifetime
├── Scanning/                    # Enumeration, byte accounting, progress, cancellation
├── Accounting/                  # Volume capacity, purgeable space, unattributed residual
├── Analysis/                    # Filtering, category breakdown, duplicate detection
├── Treemap/                     # Squarified layout, canvas rendering, hit testing
├── Cleanup/                     # Trash removal, undo, protected-path guards, history
├── Models/                      # SwiftData records and in-memory value types
├── Views/                       # SwiftUI views for outline, treemap, inspector, dialogs
└── Support/                     # Logging, size formatting, unit conventions

SpacelyzerTests/                 # Swift Testing, fixture-tree based
└── Fixtures/                    # Builders that construct temporary trees on demand

SpacelyzerUITests/               # XCUITest coverage of the primary flows
```

**Structure Decision**: A single app target with folders grouped by capability rather than by
technical layer, because the capabilities in this feature are largely independent of one another
and each maps to a user story: `Scanning` and `Accounting` serve stories 1 and 2, `Treemap` serves
story 3, `Analysis` serves story 5, and `Cleanup` serves stories 6 and 7. This keeps a story's code
in one place and keeps the pure logic — traversal, layout, filtering, guard evaluation — free of
SwiftUI so it can be tested against fixture trees without a running interface, as Principle IV
requires.

The existing Xcode template files `Spacelyzer/Item.swift` and the placeholder list in
`Spacelyzer/ContentView.swift` are scaffolding with no relationship to this feature and are removed
as part of the first implementation task.

## Complexity Tracking

> Filled because the Constitution Check records one conditional item.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Scan results held in an in-memory node store rather than SwiftData, which Principle V makes the default | The stated targets are 500,000 items measured in under 60 seconds and filters applied over 1,000,000 items within 200 ms. These are in-memory figures. A managed object graph of a million rows with recursive size rollups and per-keystroke predicate evaluation is unlikely to reach them, and one managed object per file also breaches the 500 MB memory constraint. | SwiftData has not been rejected — it has not yet been measured. Principle V permits deviation only on recorded measurement, so the deviation is provisional and the benchmark is the first implementation task. If SwiftData meets SC-001 and SC-009 on a 500,000-node fixture, it is used and this row is withdrawn. |
