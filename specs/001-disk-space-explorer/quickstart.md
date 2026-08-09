# Quickstart: Validating Disk Space Explorer

**Date**: 2026-08-08 | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

How to build the feature, run its tests, and confirm each user story actually works. Scenarios are
ordered by story priority, so the list doubles as an incremental acceptance run: after story 1 is
built, section 1 should pass and later sections will not yet apply.

---

## Prerequisites

- macOS 26.5 or later, matching the deployment target.
- Xcode with the macOS SDK. Command Line Tools alone are not sufficient.
- **Point the toolchain at Xcode before building.** If `xcode-select -p` answers
  `/Library/Developer/CommandLineTools`, `xcodebuild` fails with a "requires Xcode" error that
  says nothing about the cause:

```bash
xcode-select -p                                # expect a path inside Xcode.app
sudo xcode-select -s /Applications/Xcode.app   # only if it is not
xcodebuild -version
```

- No network access is needed at any point, for the build or the tests. If something you add starts
  requiring it, that is a Principle I violation rather than an environment problem.
- **Grant automation permission before running the UI tests.** Without it the runner fails with
  `Timed out while enabling automation mode` and the whole `xcodebuild test` invocation reports
  failure even though the unit tests passed. Grant Xcode accessibility and automation rights under
  System Settings, Privacy & Security, or run the UI tests from the Xcode GUI once to trigger the
  prompt. This is an environment issue, not a code failure, but merge gate 2 cannot be satisfied
  until it is cleared.
- **Grant Full Disk Access to the built app before running the accounting scenarios.** The app is
  unsandboxed, but privacy-protected locations such as Desktop, Documents, and Downloads still
  require the grant. Add the built binary under System Settings, Privacy & Security, Full Disk
  Access, then relaunch it; the grant does not usually take effect in a running process. Scenarios
  1 and 3 through 8 work without it. Scenario 2 will legitimately report a large volume of skipped
  locations until it is granted, which is itself worth observing once.

---

## Build and test

The project has one shared scheme, `Spacelyzer`, and two test targets.

```bash
# Build
xcodebuild build -project Spacelyzer.xcodeproj -scheme Spacelyzer -destination 'platform=macOS'

# All tests
xcodebuild test -project Spacelyzer.xcodeproj -scheme Spacelyzer -destination 'platform=macOS'

# Unit tests only, while iterating
xcodebuild test -project Spacelyzer.xcodeproj -scheme Spacelyzer -destination 'platform=macOS' \
  -only-testing:SpacelyzerTests
```

Anyone building this without the project's signing team appends the same three settings CI uses,
which sign it to run on the machine that built it and nowhere else:

```bash
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

The same two invocations run on every push and pull request through
[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml), as separate jobs so that a flake in
the interface tests reads as a flake in the interface tests. `main` takes nothing that has not
passed both.

Merge gate 1 in the constitution requires a clean build in both configurations with no new
warnings, so check Release too before calling a change done:

```bash
xcodebuild build -project Spacelyzer.xcodeproj -scheme Spacelyzer -configuration Release \
  -destination 'platform=macOS'
```

Verify the sandbox is off and Hardened Runtime is on by inspecting the signed product rather than
trusting the build settings:

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/Spacelyzer-*/Build/Products/Debug/Spacelyzer.app"
codesign -d --entitlements - --xml $APP | plutil -p -   # expect no com.apple.security.app-sandbox
codesign -d -v $APP 2>&1 | grep flags                   # expect flags=0x10000(runtime)
```

A local Release build is signed with your Apple Development identity and therefore carries
`com.apple.security.get-task-allow`, which permits debugger attachment. That is expected locally
and unacceptable for distribution: notarization rejects it. Release artifacts intended for users
must be Developer ID signed and notarized, which drops that entitlement.

---

## Fixtures

Every automated test runs against a temporary tree built at test time, never against a real home
directory and never against a hardcoded path. A fixture builder creates a directory under the
system temporary location, populates it with a known arrangement, and removes it on teardown.

Fixtures needed to cover the scenarios below: a tree with known sizes and a single dominant file; a
tree containing a hard link to an existing file; a tree containing a symbolic link pointing to an
ancestor; a directory with permissions removed; several byte-identical files under different names;
several equal-sized files with differing contents; and a generated tree of at least 500,000 entries
for the performance runs.

The large fixture is slow to build, so it belongs in a separate performance test that is run
deliberately rather than on every invocation.

---

## The storage benchmark, since closed

This section once held the gate that had to clear before any implementation began: Principle V
requires SwiftData unless a recorded measurement says otherwise, so the two candidates had to be
measured before either was built on.

It was run, and it reversed the decision. Materialising one model object per file cost between 4.7
and 15 times the price of reading the entire tree, which at 500,000 items would have spent the
whole of SC-001's budget on the import alone. Scan results are now the value tree the engine
already produces, and SwiftData holds only the durable records. Research
[R5](./research.md#r5-where-scan-results-live) records the numbers and what they changed.

What that run did not settle is whether the architecture it chose meets SC-001, SC-002, SC-005,
and SC-009 at full scale — it was measured at 50,502 nodes, and those criteria are written at
500,000 and 1,000,000. Scenarios 1, 3, and 5 below carry those figures, and they remain the open
half of the question rather than a formality.

---

## Validation scenarios

### 1. Scan a location and browse the result (Story 1)

Choose the fixture root through the folder chooser and start a scan. Expect progress to update
continuously, the hierarchy to appear ordered largest first, and each row to carry size, share of
parent, and item count. Expand to a leaf and confirm the reported size matches the fixture.

Cancel a scan of the large fixture partway. Expect control to return within **1 second** (SC-003),
partial results to remain on screen, and the result to be labeled incomplete.

Scan the fixture containing an unreadable directory. Expect the scan to complete, the readable
portion to be correct, and the unreadable location to be listed with its reason.

Scan the hard-link fixture. Expect the linked bytes to be counted exactly once in the total while
the file still appears at both of its paths. Scan the symlink-to-ancestor fixture and expect
completion without a loop and without inflated totals.

Performance: the 500,000-item fixture completes in under **60 seconds** (SC-001), with first
partial results visible within **3 seconds** (SC-002).

### 2. Reconcile the totals (Story 2)

Scan a real volume root. Expect capacity, used, and free to be shown alongside the measured total,
and any difference to be itemized rather than left blank. Add the itemized causes to the measured
total and confirm the sum lands within **1%** of the volume's used figure (SC-007).

Confirm no unexplained gap is ever displayed: the residual itself must be named and sized (SC-008).
Exclude a folder, rescan, and confirm its absence is reported as a deliberate exclusion and is
visibly distinct from a permission failure.

Revoke access to a protected location, start a scan, and expect a warning naming what will be
missing *before* results appear. Grant access while the app is running and expect an offer to
rescan.

### 3. Read the treemap (Story 3)

Scan the fixture whose dominant file is roughly half the total. Expect its rectangle to occupy
roughly half the area, nested items to be drawn inside their parents with visible boundaries, and
colors to distinguish categories with a legend present.

Hover a rectangle and expect path and size without clicking. Drill in and back out. On the large
fixture, confirm items too small to draw are combined into a labeled remainder region rather than
vanishing, and that interaction stays responsive within **100 ms** at a million items (SC-005).

Rescan unchanged data and confirm the layout is identical — rectangles must not reshuffle.

### 4. Move between the views (Story 4)

Select a deeply nested item in the outline and confirm its region highlights in the treemap. Click
a different region and confirm the outline expands its ancestors, selects it, and scrolls it into
view. Both directions must complete within **100 ms** (SC-004).

Drill the treemap into a root that excludes the current selection and confirm the selection
resolves to a defined state rather than leaving the views disagreeing.

With VoiceOver enabled, navigate the outline end to end and confirm every treemap operation is
reachable, and that focusing a drawn treemap node announces its name, size, and share.

### 5. Narrow the result (Story 5)

Apply a name filter and confirm both views show the same subset with a correct match count and
total. Apply a minimum size filter, then combine filters, then clear them in one action. On the
million-item fixture, filter changes must apply within **200 ms** (SC-009).

Open the category breakdown, confirm ranking by size and that shares sum correctly, and confirm
selecting a category filters both views. Produce it from an existing scan within **2 seconds**
without rescanning (SC-010). Apply a filter matching nothing and confirm the empty state explains
itself and offers a single clear action.

### 6. Inspect before acting (Story 6)

The panel is closed until asked for, and closes again whenever an analysis starts, so open it from
the Details button in the toolbar first. Deciding whether a large file matters means seeing it and
its place in the scan at once, which is why it takes a column beside both views rather than
covering either.

Select a known image and a known document. Expect a preview inside the app within **1 second** for
files up to 100 MB (SC-011), reveal to open the file browser with the item selected, and details to
show path, size, kind, and all three dates — created, modified, and last opened. Select a file with
no available preview and expect an explanation rather than a blank panel.

Click quickly through a dozen treemap rectangles in turn. Expect the facts to keep up with the
clicking and the preview to fill in behind them: previews are commissioned only once a selection
holds still, because each one is real work in another process and a selection passed through on
the way somewhere else should not commission any.

### 7. Reclaim space, then undo (Story 7)

Select a throwaway fixture folder and request removal. Expect the confirmation to name what will
go and report the correct count and reclaimable total before anything is touched. Complete it,
confirm the items are in the Trash and both views updated without a rescan, then undo from the
summary and confirm they return to their original locations.

Selecting more than one item at a time is not yet possible: the removal machinery takes any number
and a folder already stands for every file beneath it, but the selection itself still holds a
single path. T111a covers the gap. Until it closes, the multi-item cases below are reached by
selecting a folder whose contents include the item in question.

Try to remove the analysed folder itself, or any protected system location, and confirm it is
refused with an explanation while anything else in the same request still proceeds. Remove a
folder where one item has been deleted externally first, and confirm the rest complete with an
accurate summary. Choose permanent deletion and confirm the separate irreversibility warning
appears and that undo afterwards reports it cannot be taken back rather than claiming success.

Empty the Trash after a removal and confirm undo explains precisely why it cannot restore.

### 8. Find duplicates (Story 8)

Run detection over the identical-files fixture. Expect one set with the correct recoverable total,
ranked among any others by recoverable space, and expect the app to refuse any selection that would
remove the last remaining copy. Run it over the equal-size-different-content fixture and expect no
set at all. Over 100,000 files, detection completes within **5 minutes** with no false positives
(SC-015).

---

## Privacy check

Applies to every scenario. With the app running any operation, confirm there is no network
activity for the lifetime of the process (SC-016), and confirm the app declares no network
entitlement.

Nothing needs redacting from captured logs, because there are none: the app builds no logger and
calls no logging function anywhere, so no path is ever written outside the window it is displayed
in. Confirm that remains true rather than confirming the redaction — a `Logger` added later would
be the thing to catch, and by then the redaction question is live again.
