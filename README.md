# Spacelyzer

[![CI](https://github.com/k-electron/spacelyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/k-electron/spacelyzer/actions/workflows/ci.yml)

A native macOS disk space analyzer. Point it at a volume or a folder, and it measures what is
there, draws it as a treemap beside a browsable tree, and lets you reclaim space without losing
anything by accident.

Everything stays on your Mac. The app has no networking code in it at all — not analytics, not
crash reporting, not remote configuration.

## What it does today

- Measures a volume or folder and shows the result as a tree and a treemap, with the two kept in
  step: selecting in either highlights in the other.
- Reconciles what it measured against what the volume reports, and names every reason for the
  difference rather than presenting an unexplained gap.
- Filters by name, kind, extension, size, and age, and breaks a result down by kind.
- Shows what any item actually is — a Quick Look preview, both size figures when they differ, and
  the dates — before you decide its fate.
- Removes what you select to the Trash, after showing you the list, and puts it back if you change
  your mind.

Duplicate detection is specified but not yet built. See
[specs/001-disk-space-explorer/tasks.md](specs/001-disk-space-explorer/tasks.md) for what is done
and what is not.

## Requirements

- macOS 26.5 or later
- Xcode 26.5 or later (the project builds against the macOS 26.5 SDK and uses the Swift 6 language
  mode)

## Building it

```bash
git clone https://github.com/k-electron/spacelyzer.git
cd spacelyzer
open Spacelyzer.xcodeproj
```

Then build and run the `Spacelyzer` scheme.

### If Xcode complains about signing

The project carries the original author's development team, which you will not have. Either set
your own in the target's **Signing & Capabilities** tab, or build from the command line, where you
can sign the app to run locally and skip the question:

```bash
xcodebuild build \
  -project Spacelyzer.xcodeproj \
  -scheme Spacelyzer \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

The built app lands under `~/Library/Developer/Xcode/DerivedData/Spacelyzer-*/Build/Products/Debug/`.

### A note on Full Disk Access

Spacelyzer deliberately runs without the App Sandbox, because a sandboxed app cannot enumerate
volumes or see space held by system snapshots, and those limits are incompatible with the point of
it. It works without any special permission, but macOS will hide some locations from it until you
grant **Full Disk Access** in System Settings → Privacy & Security. The app never presents itself
as requiring that, and it reports the resulting gap in coverage rather than passing an incomplete
measurement off as a complete one.

## Running the tests

```bash
xcodebuild test \
  -project Spacelyzer.xcodeproj \
  -scheme Spacelyzer \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

Unit tests alone, which is the fast loop:

```bash
xcodebuild test -project Spacelyzer.xcodeproj -scheme Spacelyzer \
  -destination 'platform=macOS' -only-testing:SpacelyzerTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

**What the tests do to your machine.** Every test builds its own tree under the system temporary
directory or a uniquely named folder in `~/Library/Caches`, and no test reads a real home
directory. The removal tests are the exception worth knowing about: they move their own fixture
files to the real Trash, because a fake Trash would only test the fake, and then take them back out
again. The interface test that drives a real deletion reads the confirmation dialog before agreeing
to it and fails rather than proceeding if the app ever proposes anything but its own fixture.

The interface tests drive the real app, so they need a logged-in graphical session and will move
the pointer and take focus while they run.

## How the project is organised

```
Spacelyzer/
├── Access/       Volume enumeration, folder selection, exclusion rules
├── Accounting/   Reconciling the measurement against what the volume reports
├── Analysis/     Filtering and the breakdown by kind
├── Cleanup/      The guard, removal, and undo
├── Models/       SwiftData records and in-memory value types
├── Scanning/     Traversal and the scan engine
├── Support/      Size formatting, activity indication, file kinds
├── Treemap/      Squarified layout, canvas drawing, hit testing
└── Views/        The window and everything in it
```

The app has no third-party dependencies. Scan results are held as a value tree for the session and
never written to disk; only small durable records — exclusions, recent locations, preferences, and
removal history — go to SwiftData.

## How it is built

This is a spec-driven project. Two documents govern it and are worth reading before changing
anything:

- [`.specify/memory/constitution.md`](.specify/memory/constitution.md) — the principles the code
  answers to, including the no-network guarantee, guarded deletion, and the responsiveness rules.
- [`specs/001-disk-space-explorer/`](specs/001-disk-space-explorer/) — the specification, plan,
  research notes, interface contracts, and task list for the feature being built.

Behaviour that diverges from those documents is a defect in one of them. They are kept in step with
the code deliberately, so a change that alters behaviour changes the document that described it.

## Licence

None yet, which in practice means all rights reserved. Open an issue if you want to use this for
something.
