# Implementation Plan: Disk Space Explorer

**Branch**: `main` (feature directory `001-disk-space-explorer`; no feature branch was created)
| **Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-disk-space-explorer/spec.md`

## Summary

Spacelyzer measures a user-chosen folder or volume, presents the result simultaneously as a
navigable outline and a proportional treemap bound by one shared selection, and lets the user
narrow, inspect, and safely reclaim what it finds. The technical approach is a bulk-enumerated,
cancellable, concurrent scan feeding a SwiftData store that both views read from, configured
in-memory so results vanish on quit, with durable state limited to exclusions, recent locations,
and removal history. Everything runs locally with no network access and no third-party
dependencies.

The plan was first written against a sandboxed app and has been revised. Research established that
the App Sandbox made three requirements unimplementable — the volume picker, direct filesystem
reach, and any sizing of snapshot space — and constitution v2.0.0 responded by dropping the sandbox
in favour of Developer ID direct distribution. The app now enumerates volumes itself, reads
directly, and sizes snapshots through a system tool with a stated fallback. In exchange the
operating system no longer constrains what it can delete, which makes the removal guards in
Principle II load-bearing in a way they were not before.

## Technical Context

**Language/Version**: Swift, Swift 6 language mode. The project is currently configured for Swift
5.0 with approachable concurrency enabled; moving to Swift 6 is a required build-setting change
recorded in [research.md](./research.md) R8.

**Primary Dependencies**: None outside the platform SDK. SwiftUI, SwiftData, Foundation, AppKit
interop, QuickLookUI, UniformTypeIdentifiers, CryptoKit, and OSLog. Zero third-party packages are
planned, so Principle VI's license, reputation, and version obligations do not yet apply.

**Storage**: SwiftData throughout, in one container with two configurations. Scan results use an
in-memory-only configuration and vanish on quit; exclusion rules, recent locations, removal
history, and preferences are written to disk. This follows Principle V's default, so no measurement
is required.

**Testing**: Swift Testing for unit coverage of traversal, accounting, layout, filtering, duplicate
grouping, and removal guards, all exercised against temporary fixture trees. XCUITest for the
primary user flows: scan, select across both views, filter, and a guarded removal with undo.

**Target Platform**: macOS 26.5 and later, built against the macOS SDK. The App Sandbox is
disabled; Hardened Runtime remains enabled in every configuration, and releases are Developer ID
signed and notarized. Coverage of privacy-protected locations depends on the user granting Full
Disk Access.

**Project Type**: Native macOS desktop application, single app target with two test targets.

**Performance Goals**: 500,000 items measured in under 60 seconds (SC-001); first partial results
within 3 seconds (SC-002); cancellation effective within 1 second (SC-003); cross-view selection
propagation within 100 ms (SC-004); treemap interaction within 100 ms at 1,000,000 items (SC-005);
filter application within 200 ms at 1,000,000 items (SC-009); category breakdown within 2 seconds
without rescanning (SC-010); preview within 1 second for files up to 100 MB (SC-011).

**Constraints**: Nothing whose cost scales with the size of a scan may run on the main actor, which
puts filtering, treemap layout, and the category breakdown off it despite their being pure
functions. Any operation still running after roughly 150 milliseconds shows that it is working, and
anything exceeding two seconds reports incremental progress. Read access depends on the user
granting Full Disk Access, never on an entitlement. No network access of any kind. Reported sizes
are space occupied on disk, in decimal units by default, with logical length shown in item details.
No memory ceiling is stated: one model object per file rules out the tight bound an earlier draft
carried, and inventing a looser one would be a number nobody had measured.

**Scale/Scope**: 8 prioritized user stories, 68 functional requirements, 16 success criteria.
Working set up to roughly 1,000,000 nodes per scan.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Status | Basis |
|---|---|---|
| I. Local-First and Private by Default (NON-NEGOTIABLE) | Pass | No feature needs the network, no networking code is planned, and nothing about the user's files leaves the machine. Without the sandbox there is no operating-system enforcement, and v2.1.0 deliberately declined to add build-time policing in its place; this rests on the commitment not to build such a feature. Logging goes through OSLog with paths marked private. |
| II. Destructive Actions Are Guarded (NON-NEGOTIABLE) | Pass | Removal is explicit-selection only, previewed before it runs, routed to the Trash by default, refused for protected locations before the confirmation appears, cancellable, and reversible for the most recent batch. The guards live in `RemovalGuard` and `DuplicateSet` rather than in any view, satisfying v2.0.0's requirement that no interface change can route around them. |
| III. Never Block, Always Show Progress | Pass | Traversal, hashing, filtering, layout, and removal all run off the main actor, and scan cancellation is checked at every directory batch boundary. FR-069 through FR-071 now carry the visibility and non-blocking obligations, and SC-017 makes them measurable. |
| IV. Verified Before Merge | Pass | Scan, accounting, layout, filter, and removal-guard logic are unit-testable against fixture trees; no test touches a real home directory. |
| V. Native and Minimal | Pass | SwiftUI, SwiftData throughout, and zero third-party dependencies. Storage follows the principle's stated default, so no measurement or justification is needed. The treemap accessibility gap is resolved by research R7. |
| VI. Dependencies Are Open, Proven, and Current | Pass | No third-party dependency is planned. If one is later proposed it must clear this principle before adoption. |
| VII. Docs and Code Stay in Sync | Pass | The sandbox change was propagated in the same commit as the amendment: build settings, spec, research, contracts, and this plan all moved together. An earlier version of this row claimed the constitution recorded Swift 5.0 as a project fact; it never did, and no amendment is needed when the language mode changes. |
| VIII. Only Intended Files Are Committed | Pass | The root `.gitignore` already covers macOS, Xcode, build, and credential artifacts, and no new class of generated output is introduced. |

### Gate items that must close before implementation starts

1. ~~Amend FR-017.~~ **Closed.** Dropping the sandbox made snapshot sizing reachable through
   `diskutil apfs listSnapshots`. FR-017 keeps its requirement and gains a fallback: where a size
   cannot be determined the space falls through to the unattributed residual with the reason
   stated, so SC-008 holds even when the parser breaks.
2. ~~Measure before deviating from SwiftData.~~ **Closed.** The decision is to use SwiftData
   throughout, with scan data in an in-memory-only configuration. Following Principle V's default
   requires no measurement; only deviating did. The performance risk this accepts is recorded in
   research R5.
3. ~~Extend the spec's progress obligations.~~ **Closed.** FR-069 through FR-071 and SC-017 now
   carry the visibility, incremental-progress, and non-blocking rules for removal, restoration,
   preview, filtering, and the category breakdown.
4. ~~Build an automated no-network check.~~ **Withdrawn.** Briefly required by v2.0.0 and removed
   again in v2.1.0. The prohibition on networking code stands; enforcing it with tooling was judged
   disproportionate for a codebase that has no reason to reach the network and no plans to.

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

Re-checked a third time against constitution v2.1.0, after the App Sandbox was removed. Snapshot
sizing became reachable, so FR-017 stands with a fallback rather than being relaxed. Volume
enumeration became possible, so FR-001 now requires a volume picker instead of an open panel, and
the `AccessBroker` contract was rewritten accordingly. Principle I did lose its enforcement
mechanism along the way — an entitlement the app declines to declare means nothing outside a
sandbox — and the deliberate decision was to accept that rather than replace it with build-time
policing, on the grounds that the app has no reason to reach the network and no plans to.

The sandbox change was verified against the signed product rather than the build settings: neither
configuration carries the sandbox entitlement, Hardened Runtime remains on, and both Debug and
Release build clean.

All four gate items are now closed or withdrawn. The storage question closed by choosing SwiftData
throughout rather than by measuring an alternative, which is the compliant default and removes the
custom node store, the hand-rolled filter index, and the benchmark along with it. The performance
risk that decision accepts is stated in research R5 rather than hidden: a million model objects may
not reach SC-005 or SC-009, and no revisit trigger is pre-committed. Implementation may begin.

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
├── Access/                      # Volume enumeration, folder chooser, Full Disk Access state
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

> Empty. The Constitution Check records no violations to justify.

The one entry this section previously carried — holding scan results outside SwiftData — was
withdrawn when the storage decision settled on SwiftData throughout. Following a principle's stated
default needs no justification, so there is nothing to track here.
