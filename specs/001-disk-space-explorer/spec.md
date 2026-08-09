# Feature Specification: Disk Space Explorer

**Feature Branch**: `main` (no feature branch created; spec directory is `001-disk-space-explorer`)

**Created**: 2026-08-08

**Status**: Draft

**Input**: User description: "Select a folder or a drive, scan it, and build a treemap of what is
consuming space. Provide a tree-style explorer on the left for easy browsing, where any selection
highlights the corresponding space consumption in the treemap on the right. Selection must work
bidirectionally: choosing a region in the treemap expands and reveals the matching node in the
explorer tree, and choosing a node in the tree highlights its region in the treemap. Also provide
guarded cleanup flows and duplicate detection. The treemap should be visually pleasing."

Extended after review to add four areas: accounting for space the scan cannot see so reported
totals reconcile with the volume, search and filtering with a breakdown by file category,
inspection of an item before acting on it together with undo and history for removals, and
user-controlled scan exclusions.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find out where the space went (Priority: P1)

Someone is running out of room on their Mac and has no idea what is responsible. They open the
app, choose a folder or a whole volume, and watch it being measured. When measurement finishes
they see the contents laid out as an expandable hierarchy with the biggest consumers at the top,
so they can follow the trail from the largest folder down to the specific files inside it.

**Why this priority**: Answering "what is using my space" is the entire reason someone opens this
app. Every other story decorates or acts on this result, and none of them can exist without it.
Shipped alone, this is already a usable tool.

**Independent Test**: Choose a folder containing a known arrangement of files, run a scan, and
confirm the reported sizes and ordering match the known arrangement, with the largest contributor
listed first and drill-down reaching the individual files.

**Acceptance Scenarios**:

1. **Given** no scan has been run, **When** the user chooses a folder and starts a scan, **Then**
   progress is shown continuously and results appear as an expandable hierarchy ordered largest
   first.
2. **Given** a scan is running over a large location, **When** the user cancels it, **Then**
   measurement stops promptly and the partial results gathered so far remain visible and are
   clearly labeled as incomplete.
3. **Given** a location contains folders the user has not granted access to, **When** the scan
   completes, **Then** the readable portion is reported normally and the skipped locations are
   listed with the reason each was skipped.
4. **Given** a completed scan, **When** the user expands a folder, **Then** its children appear
   with each child's size, its share of its parent, and how many items it contains.

---

### User Story 2 - Trust the totals (Priority: P2)

The user scans their startup disk and the app reports 120 GB while the Mac reports 200 GB used.
Rather than leaving them to conclude the app is broken, the app accounts for the whole volume: what
it measured, what it could not read, what the user chose to exclude, what is held in system
snapshots, and what the system can reclaim on its own. The user may not like the answer, but the
numbers add up and they know why.

**Why this priority**: A number the user does not believe is worse than no number at all. This
story is what makes every other figure in the app credible, and the gap it explains is routinely
tens of gigabytes on a normal Mac.

**Independent Test**: On a volume holding known snapshot usage with at least one unreadable folder
and one deliberately excluded folder, confirm that the measured total plus every itemized cause
reconciles with the volume's reported used space, and that each cause is named with its own size.

**Acceptance Scenarios**:

1. **Given** a scan of a location on a mounted volume completes, **When** results are shown,
   **Then** the volume's capacity, used space, and free space appear alongside the measured total.
2. **Given** the volume reports more space used than the scan measured, **When** results are shown,
   **Then** the difference is itemized by cause rather than left as an unexplained gap.
3. **Given** the app lacks the access needed to measure a substantial part of the chosen location,
   **When** the user starts the scan, **Then** they are told before results appear what will be
   missing and how to grant the access.
4. **Given** the user grants that access while the app is running, **When** the app detects it,
   **Then** it offers to rescan.
5. **Given** a volume holds space in system snapshots or automatically reclaimable caches, **When**
   results are shown, **Then** that space is named with its size and explained in plain language
   instead of being absorbed into the unaccounted remainder.
6. **Given** the user has excluded a folder from scanning, **When** results are shown, **Then** its
   absence is reported as a deliberate exclusion, distinct from anything skipped for permissions.

---

### User Story 3 - See the shape of the disk at a glance (Priority: P3)

Reading a list of sizes is slow. The user wants a single picture where every file and folder is
drawn as a rectangle sized in proportion to the space it occupies, so that the handful of things
actually worth attention are immediately obvious without reading a single number.

**Why this priority**: The visualization is what turns a correct answer into an immediately
understandable one, but it is meaningless without the measurement from Story 1.

**Independent Test**: Scan a location containing one file that occupies roughly half the total and
confirm that its rectangle occupies roughly half the treemap area, that colors distinguish file
categories, and that hovering any rectangle reveals its path and size.

**Acceptance Scenarios**:

1. **Given** a completed scan, **When** the treemap is displayed, **Then** each item is drawn with
   an area proportional to its share of the displayed total, and nested items are drawn inside
   their parent's rectangle.
2. **Given** a treemap is displayed, **When** the user points at a rectangle, **Then** that item's
   full path and size are revealed without needing to click.
3. **Given** a treemap is displayed, **When** the user drills into a rectangle, **Then** that item
   becomes the displayed root and the user can navigate back to where they came from.
4. **Given** a scan containing far more items than can be drawn distinctly, **When** the treemap is
   displayed, **Then** items too small to render are combined into a visible remainder region
   rather than being silently omitted.

---

### User Story 4 - Move between the picture and the list without losing your place (Priority: P4)

The picture shows the user *that* something is large; the tree tells them *what* it is and where it
lives. The user needs to move between the two without hunting. Clicking a rectangle should reveal
and select that exact item in the tree, and selecting anything in the tree should light up its
territory in the picture.

**Why this priority**: This is what makes the two views feel like one tool instead of two. It
requires both views to already exist.

**Independent Test**: With both views showing the same scan, select a deeply nested item in the
tree and confirm its region is highlighted in the treemap; then click a different region in the
treemap and confirm the tree expands to reveal and select that item, scrolled into view.

**Acceptance Scenarios**:

1. **Given** both views show the same scan, **When** the user selects a node in the hierarchy,
   **Then** the matching region in the treemap is highlighted distinguishably from everything else.
2. **Given** both views show the same scan, **When** the user selects a region in the treemap,
   **Then** the hierarchy expands every ancestor as needed, selects the matching node, and scrolls
   it into view.
3. **Given** an item is selected in either view, **When** the user looks at the other view,
   **Then** exactly the same item is shown as selected, with no perceptible lag between the two.
4. **Given** a selected item, **When** the user drills the treemap into a different root that no
   longer contains the selection, **Then** the selection state is resolved unambiguously rather
   than leaving the two views disagreeing.

---

### User Story 5 - Narrow down to what actually matters (Priority: P5)

A picture of a million items is beautiful but not yet actionable. The user wants to ask pointed
questions of the result: everything over a gigabyte, every video file, anything untouched since
last year. They also want the answer to a different question than the treemap gives — not which
folder is large, but what kind of thing is filling the disk.

**Why this priority**: This converts an accurate picture into a decision. It depends on the scan
and both views already existing, but without it a large scan is something to admire rather than act
on.

**Independent Test**: Scan a folder containing a known mix of file kinds and sizes, apply a minimum
size filter, and confirm both views show exactly the matching subset with a correct match count and
total; then open the category breakdown and confirm its totals reconcile with the scan.

**Acceptance Scenarios**:

1. **Given** a completed scan, **When** the user filters by text in the name, **Then** both views
   show only matching items, and the number of matches and their total size are reported.
2. **Given** a completed scan, **When** the user filters by a minimum size, **Then** only items at
   or above that size remain in both views.
3. **Given** several filters are active at once, **When** the user clears them, **Then** both views
   return to the complete scan in a single action.
4. **Given** a completed scan, **When** the user opens the breakdown by file category, **Then**
   categories are ranked by total size with each one's size, item count, and share of the scan, and
   choosing a category filters both views to it.
5. **Given** an active filter that nothing matches, **When** results are shown, **Then** an empty
   state explains this and offers to clear the filter.

---

### User Story 6 - Look at something before acting on it (Priority: P6)

There is a four-gigabyte file called `archive_final_v2` and the user has no memory of it. Before
deciding its fate they want to see what it actually is, where it lives, and when they last touched
it, without leaving the app and losing their place in the scan.

**Why this priority**: This is the cheapest protection available against deleting the wrong thing,
and it is what makes the cleanup story safe to use in practice rather than merely guarded on paper.

**Independent Test**: Select a known image and a known document, confirm each renders a preview
inside the app, that revealing in the file browser opens the correct folder with the item selected,
and that the reported path, size, and dates match the real file.

**Acceptance Scenarios**:

1. **Given** an item is selected in either view, **When** the user previews it, **Then** its
   contents are shown within the app without opening another application.
2. **Given** an item is selected, **When** the user chooses to reveal it, **Then** the system file
   browser opens with that item selected.
3. **Given** an item is selected, **When** the user views its details, **Then** the full path, size
   on disk, kind, and the created, modified, and last-accessed dates are shown.
4. **Given** an item that cannot be previewed, **When** the user previews it, **Then** a clear
   explanation appears instead of an error or an empty panel.

---

### User Story 7 - Reclaim space without losing anything important (Priority: P7)

Having found the offenders, the user wants to remove them. They select one or more items from
either view, review exactly what is about to happen, and confirm. Nothing disappears without them
having seen the list first, anything removed can be brought back, and if they change their mind
immediately they can undo the whole batch.

**Why this priority**: Removal is the payoff, but it is also the only irreversible thing this app
does. It ships after the user can reliably see, verify, and inspect what they are selecting.

**Independent Test**: Select a known set of throwaway files, confirm the removal dialog reports the
correct count and reclaimable total, complete the removal, verify the files are recoverable from
the Trash and both views updated, then undo the batch and confirm the files return to their
original locations.

**Acceptance Scenarios**:

1. **Given** items are selected, **When** the user requests removal, **Then** a confirmation lists
   the affected items, their count, and the total space to be reclaimed, before anything is
   touched.
2. **Given** a confirmed removal, **When** it completes, **Then** the items are recoverable from
   the Trash and both views reflect the reclaimed space without requiring a fresh scan.
3. **Given** a selection that includes a protected system location, **When** the user requests
   removal, **Then** the protected items are refused with an explanation and the remaining items
   can still proceed.
4. **Given** a removal of many items, **When** some fail because they are in use or already gone,
   **Then** the remainder still complete and a summary reports exactly what succeeded and what did
   not.
5. **Given** the confirmation is shown, **When** the user chooses permanent deletion instead of the
   Trash, **Then** they are warned explicitly that it cannot be undone and must confirm separately.
6. **Given** a completed removal to the Trash, **When** the user undoes it, **Then** the items
   return to their original locations and both views update to reflect this.
7. **Given** the Trash has been emptied since a removal, **When** the user attempts to undo it,
   **Then** the app explains that undo is no longer possible rather than reporting a success that
   did not happen.
8. **Given** several removals have taken place, **When** the user reviews the history, **Then** each
   one is listed with what was removed, when, how much space it freed, and whether it went to the
   Trash or was deleted permanently.

---

### User Story 8 - Find the same file stored several times (Priority: P8)

Space is often wasted on identical copies scattered across different folders. The user asks the app
to find files whose contents are the same, sees them grouped with the amount recoverable, and can
clear out the redundant copies while always keeping one.

**Why this priority**: Valuable but narrower than the main flow, and it depends on both the scan
results and the guarded removal flow being trustworthy first.

**Independent Test**: Place several byte-identical files with different names in different folders,
run duplicate detection, and confirm they are grouped as one set with the correct recoverable total
and that the app refuses any action that would delete every copy.

**Acceptance Scenarios**:

1. **Given** a completed scan, **When** the user runs duplicate detection, **Then** progress is
   reported and the operation can be cancelled.
2. **Given** duplicate detection has finished, **When** results are shown, **Then** files with
   identical contents are grouped into sets ordered by how much space could be recovered.
3. **Given** a duplicate set, **When** the user selects copies to remove, **Then** the app prevents
   removing the final remaining copy in that set.
4. **Given** files with identical names and sizes but different contents, **When** duplicate
   detection runs, **Then** they are not reported as duplicates.

---

### Edge Cases

- A folder cannot be read because the user has not granted access, or the operating system
  withholds it: the scan continues, and the location is reported as skipped with the reason.
- The volume reports far more space used than the scan can find even with full access granted: the
  remainder is attributed to named causes such as snapshots and reclaimable caches, and whatever
  still cannot be explained is shown as an explicit unaccounted figure rather than hidden.
- Access is granted part-way through a session: the app notices and offers a rescan instead of
  continuing to present results it knows are incomplete.
- The same underlying data is reachable by more than one name or path: it is counted once, so
  totals are not inflated.
- A symbolic link points to an ancestor of itself, or to somewhere already measured: traversal
  neither loops forever nor double counts.
- Files are created, grown, or deleted while the scan is running: results describe a point in time
  and do not crash or report negative or impossible sizes.
- A removable or network volume is unmounted mid-scan: the scan ends gracefully and explains what
  happened rather than hanging.
- A scan is started on a location that turns out to be empty, or every item in it is zero bytes:
  the views render an empty state instead of an unreadable or divide-by-zero visualization.
- The scan contains millions of items, most of them tiny: the treemap stays interactive and
  aggregates undrawable items rather than freezing or hiding them without trace.
- An item selected in one view has been removed or is no longer present in the current treemap
  root: selection resolves to a sensible state rather than a stale or invisible selection.
- A filter is active when items are removed: match counts and totals update to stay correct rather
  than continuing to describe items that no longer exist.
- A filter excludes every item in the scan: the empty state explains why nothing is shown and
  offers a single action to clear it.
- An exclusion is added or removed after a scan has already run: the existing result is marked as
  no longer reflecting the current settings rather than silently changing.
- The user excludes the scan root itself: this is refused with an explanation rather than producing
  an empty scan.
- The Trash is unavailable for the volume in question, for example on some external media: the user
  is told before the removal proceeds, not after.
- Undo is attempted after the Trash has been emptied, or the original folder no longer exists: the
  app explains precisely why it cannot restore rather than failing silently or partially.
- An item is removed outside the app while results are on screen: the app reports the discrepancy
  rather than showing space that no longer exists.
- An item has no preview available, or is far too large to preview quickly: the app explains this
  instead of stalling or presenting a blank panel.
- Duplicate detection is run over a set containing very large files: it remains cancellable and
  reports progress rather than appearing frozen.

## Requirements *(mandatory)*

### Functional Requirements

**Choosing and measuring a location**

- **FR-001**: Users MUST be able to choose any readable folder or mounted volume as the scan root,
  and the system MUST present the available mounted volumes directly rather than requiring the user
  to navigate to one through a file chooser.
- **FR-002**: System MUST obtain the user's consent before reading locations the operating system
  protects, and MUST continue with the rest of the scan if consent is withheld.
- **FR-003**: System MUST display continuous progress while scanning, including what is currently
  being measured and a running total of data measured so far.
- **FR-004**: Users MUST be able to cancel a scan at any point; measurement MUST stop within one
  second and partial results MUST remain available, clearly labeled as incomplete.
- **FR-005**: System MUST skip items it cannot read and MUST present a reviewable summary of every
  skipped location together with the reason.
- **FR-006**: System MUST count each unit of stored data at most once per scan, even when it is
  reachable through multiple names or paths.
- **FR-007**: System MUST NOT follow symbolic links in a way that revisits measured content or
  traverses indefinitely.
- **FR-008**: System MUST report, for every folder, both the size of its immediate contents and the
  cumulative size of everything beneath it.
- **FR-009**: Users MUST be able to rescan the current location and MUST be able to return to
  recently scanned locations without navigating to them again.
- **FR-010**: Users MUST be able to exclude specific folders from a scan before starting it.
- **FR-011**: The exclusion list MUST persist across scans and across sessions, and MUST be
  reviewable and editable by the user.
- **FR-012**: System MUST refuse an exclusion that would exclude the scan root itself, explaining
  why.
- **FR-013**: Changing the exclusion list MUST NOT silently alter an existing result; the system
  MUST indicate that the displayed result no longer reflects current settings and that a rescan is
  required.

**Accounting for the whole volume**

- **FR-014**: When the scan root sits on a mounted volume, system MUST display that volume's total
  capacity, used space, and free space alongside the measured total.
- **FR-015**: System MUST show the difference between the space the volume reports as used and the
  space the scan measured, and MUST NOT present the measured total as though it were the whole
  volume.
- **FR-016**: That difference MUST be itemized by cause, covering at minimum locations denied by
  permission, locations excluded by the user, space held by system snapshots, space held by volumes
  sharing the same physical drive that a scan cannot reach, and any remainder that cannot be
  attributed. Where the scan measured a folder rather than a whole volume, the unmeasured rest of
  the volume MUST be named as a cause rather than presented as unexplained.
- **FR-017**: System MUST name space held by snapshots as a distinct category with its size, and
  MUST explain in plain language why that space is not visible as ordinary files. Where a size
  cannot be determined, that space MUST fall through to the unattributed remainder with the reason
  stated; it MUST NOT be reported as zero and MUST NOT be quietly omitted.
- **FR-017a**: System MUST name and size space the system can reclaim automatically, and MUST
  present it as a property of the space already in use rather than as a cause of the difference in
  FR-015. It is counted inside the volume's used figure and consists largely of files the scan
  measured, so adding it to the itemization in FR-016 would claim the same bytes twice. Research R4
  records the measurement behind this.
- **FR-018**: When the app lacks access to one or more locations that the operating system protects
  by default, system MUST inform the user before presenting results, name each location that will
  be missing, and provide guidance for granting the access.
- **FR-019**: When the missing access is subsequently granted, system MUST detect this and offer to
  rescan.
- **FR-020**: Sizes MUST be displayed using the same unit convention the operating system uses in
  its own reporting, and the convention in force MUST be discoverable by the user.
- **FR-021**: Users MUST be able to switch between decimal and binary size conventions, and every
  displayed size MUST update consistently when they do.

**Browsing the hierarchy**

- **FR-022**: System MUST present results as an expandable hierarchy mirroring the folder structure
  of the scanned location. Application bundles MUST appear as single items by default, and MUST be
  expandable only when the user explicitly chooses to look inside one, at which point their
  contents are measured on demand.
- **FR-023**: Each entry MUST show its name, cumulative size, share of its parent, and the number of
  items it contains.
- **FR-024**: Children MUST be ordered largest first by default, and users MUST be able to reorder
  by name, size, item count, and date modified.
- **FR-025**: Users MUST be able to expand, collapse, and move through the hierarchy using the
  keyboard alone.
- **FR-026**: The hierarchy and the treemap MUST be presented side by side, with the hierarchy on
  the leading side and the treemap on the trailing side, and the divider between them MUST be
  adjustable by the user.

**Visualizing the result**

- **FR-027**: System MUST draw a treemap in which each item's area is proportional to its share of
  the currently displayed total.
- **FR-028**: The treemap MUST draw nested items entirely within the bounds of their parent, and
  MUST render a visible boundary around each item so that a viewer can determine which parent any
  rectangle belongs to.
- **FR-029**: The treemap MUST use color to distinguish categories of file, and MUST provide a
  legend explaining the mapping.
- **FR-030**: Pointing at any region MUST reveal that item's full path and size without a click.
- **FR-031**: Users MUST be able to drill into any region so it becomes the displayed root, and MUST
  be able to navigate back out again.
- **FR-032**: When items are too small to draw distinctly, the treemap MUST combine them into a
  visible remainder region rather than omitting them silently.

**Linking the two views**

- **FR-033**: Selecting an entry in the hierarchy MUST highlight the corresponding region in the
  treemap in a way that is clearly distinguishable from unselected regions.
- **FR-034**: Selecting a region in the treemap MUST expand the necessary ancestors in the
  hierarchy, select the matching entry, and scroll it into view.
- **FR-035**: There MUST be exactly one current selection shared by both views, and both views MUST
  reflect it at all times.
- **FR-036**: When the current selection is not representable in the treemap's displayed root, the
  system MUST resolve the selection to a defined state rather than leaving the views disagreeing.

**Narrowing the result**

- **FR-037**: Users MUST be able to filter a completed scan by text occurring in an item's name,
  matched without regard to letter case, and without rescanning.
- **FR-038**: Users MUST be able to filter by file category and by specific file extension.
- **FR-039**: Users MUST be able to filter by size, specifying a minimum, a maximum, or both.
- **FR-040**: Users MUST be able to filter by date modified over a range.
- **FR-041**: Filters MUST be combinable, and the set of active filters MUST be visible and
  clearable in a single action.
- **FR-042**: An active filter MUST apply to both views simultaneously, so the hierarchy and the
  treemap always describe the same subset.
- **FR-043**: System MUST report how many items match the active filters and their combined size.
- **FR-044**: System MUST present a breakdown of the scan by file category ranked by total size,
  showing each category's size, item count, and share of the scan, and selecting a category MUST
  filter both views to it.

**Inspecting an item**

- **FR-045**: Users MUST be able to preview the contents of the selected item from either view,
  within the app, without opening a separate application.
- **FR-046**: Users MUST be able to reveal the selected item in the system file browser.
- **FR-047**: Users MUST be able to open the selected item in its default application.
- **FR-048**: System MUST show, for the selected item, its full path, space occupied on disk,
  logical file length, kind, and its created, modified, and last-accessed dates. Where the occupied
  and logical figures differ, both MUST be visible rather than the difference being hidden.
- **FR-049**: Inspecting an item MUST NOT alter that item's contents or location.
- **FR-050**: When an item cannot be previewed, system MUST explain why rather than presenting an
  empty or failed preview.

**Reclaiming space**

- **FR-051**: Users MUST be able to select one or more items from either view and request their
  removal.
- **FR-052**: Before anything is removed, the system MUST present a confirmation listing the
  affected items, their count, and the total space to be reclaimed.
- **FR-053**: Removal MUST place items in the Trash by default so that they remain recoverable.
- **FR-054**: Permanent deletion MUST require a separate explicit choice within the confirmation and
  MUST warn that it cannot be undone.
- **FR-055**: System MUST refuse to remove protected system locations and its own application data,
  explaining the refusal, while allowing the remaining selection to proceed.
- **FR-056**: Removal MUST be cancellable, MUST continue past individual failures, and MUST finish
  with a summary of what succeeded and what did not.
- **FR-057**: After a removal, both views MUST update to reflect the reclaimed space without
  requiring a fresh scan.
- **FR-058**: System MUST NOT remove anything as a side effect of scanning, browsing, sorting,
  filtering, or navigating.
- **FR-059**: Users MUST be able to undo the most recent removal, returning the affected items from
  the Trash to the locations they came from.
- **FR-060**: When undo cannot be performed, whether because the Trash has been emptied, the
  original location no longer exists, or the removal was permanent, system MUST say so explicitly
  and MUST NOT report a restoration that did not occur.
- **FR-061**: System MUST keep a history of removals recording what was removed, when, how much
  space was freed, and whether items went to the Trash or were deleted permanently; users MUST be
  able to review this history and clear it.

**Finding redundant copies**

- **FR-062**: Users MUST be able to search the scanned scope for files whose contents are identical.
- **FR-063**: Identity MUST be determined by file content; matching names, sizes, or dates alone
  MUST NOT be sufficient to report a duplicate.
- **FR-064**: Duplicate sets MUST be presented ordered by the amount of space recoverable from each.
- **FR-065**: System MUST prevent any action that would remove every copy within a duplicate set.
- **FR-066**: Duplicate detection MUST report progress and MUST be cancellable.

**Trust and privacy**

- **FR-067**: System MUST operate entirely without network access, and no information about the
  user's files MUST leave the device by any means.
- **FR-068**: Scan results, the exclusion list, and the removal history MUST be stored only on the
  user's own machine.

**Keeping the user informed**

- **FR-069**: Any operation still running after roughly 150 milliseconds MUST show in the interface
  that work is in progress, and MUST keep showing it until the operation ends. Operations that
  finish sooner MUST NOT flash an indicator on and off.
- **FR-070**: Removal, restoration, preview, filtering, and the category breakdown MUST each
  indicate that they are working, and removal and restoration MUST additionally report incremental
  progress once they exceed two seconds.
- **FR-071**: Background work MUST NOT disable parts of the interface unrelated to it, and MUST NOT
  prevent the user from cancelling it.

### Key Entities

- **Scan**: One measurement of a chosen root taken at a point in time. Knows its root, when it ran,
  whether it completed or was cancelled, its totals, and what it skipped.
- **Scanned Item**: A file or folder found by a scan. Carries its name, location within the
  hierarchy, space occupied on disk, cumulative size including descendants, item count, category,
  and its created, modified, and last-accessed dates. Its logical file length is available when the
  item is inspected.
- **Scan Root**: The folder or volume a scan was told to measure, and the basis for every percentage
  shown.
- **Volume Context**: The capacity, used space, and free space reported by the volume holding the
  scan root, against which the measured total is reconciled.
- **Unaccounted Space Entry**: One named cause for the difference between the volume's used space
  and the measured total, such as denied permissions, user exclusions, snapshots, or reclaimable
  caches, paired with its size.
- **Skipped Location**: Something a scan could not read, paired with the reason, so that totals can
  be understood as incomplete.
- **Exclusion Rule**: A folder the user has chosen to leave out of scanning, persisted between
  sessions.
- **Filter**: A set of active conditions over name, category, extension, size, and modification date
  that narrows what both views display.
- **Category**: A grouping of files by kind, used for treemap coloring and for the ranked breakdown.
- **Selection**: The single item currently focused, shared by the hierarchy and the treemap.
- **Duplicate Set**: A group of two or more items with identical content, with the recoverable
  amount being the total size of all but one copy.
- **Removal Batch**: A user-confirmed group of items to remove, its chosen disposal method, and the
  per-item outcome once it has run.
- **Removal History Entry**: A durable record of one removal batch, including when it happened, what
  it freed, and whether the items remain recoverable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A scan of a location containing 500,000 items completes in under 60 seconds.
- **SC-002**: Partial results are visible within 3 seconds of a scan starting, before it completes.
- **SC-003**: Cancelling a scan returns control to the user within 1 second.
- **SC-004**: A selection made in either view appears in the other within 100 milliseconds.
- **SC-005**: The treemap continues to respond to pointing and clicking within 100 milliseconds for
  scans containing up to 1,000,000 items.
- **SC-006**: The total reported for a scanned location is within 1% of the size the operating
  system reports for that same location.
- **SC-007**: The measured total plus every itemized cause of unaccounted space reconciles with the
  volume's reported used space within 1%.
- **SC-008**: No difference between the volume's used space and the measured total is ever presented
  without a stated cause; the unexplained remainder is itself always labeled and sized.
- **SC-009**: Applying or clearing a filter updates both views within 200 milliseconds on a scan of
  1,000,000 items.
- **SC-010**: The breakdown by file category is produced from an existing scan within 2 seconds and
  never requires rescanning.
- **SC-011**: A preview of the selected item appears within 1 second for files up to 100 MB.
- **SC-012**: 90% of first-time users identify their single largest space consumer within 2 minutes
  without consulting documentation.
- **SC-013**: 100% of removals are preceded by a confirmation that names the items, and 100% of
  removals are recoverable unless the user explicitly chose permanent deletion.
- **SC-014**: Undo restores every item in the most recent removal batch whenever those items are
  still in the Trash and their original locations still exist.
- **SC-015**: Duplicate detection across 100,000 files completes within 5 minutes, and every set it
  reports is verifiably identical in content, with no false positives.
- **SC-016**: No information about scanned files leaves the device during any operation, verifiable
  by observing no network activity for the lifetime of the process.
- **SC-017**: No operation leaves the interface unchanged for longer than 150 milliseconds without
  indicating that work is in progress.

## Assumptions

- Every headline size — in the hierarchy, the treemap, totals, and reclaimable figures — is space
  actually occupied on disk, because the user's goal is reclaiming physical space. The logical file
  length is shown alongside it in an item's details, so that a file whose two figures differ, such
  as a sparse or compressed one, can be understood rather than looking like a mistake.
- Sizes are displayed in decimal units by default, matching how the operating system reports them,
  so that the two agree; the binary convention is available for users who prefer it.
- Performance targets assume an Apple silicon Mac with an internal solid-state drive scanning a
  local volume. Scans of network or removable media are supported but are not held to these targets.
- Granting the app full access to the disk is optional. Without it the app still works, and the
  resulting gap in coverage is reported rather than hidden.
- The app reports space held by snapshots and by automatically reclaimable caches, but does not
  itself delete them; removing that space is the operating system's responsibility and is out of
  scope.
- A single person uses the app on their own machine. There are no accounts, no sharing, and no
  multi-user considerations.
- Scans are started by the user. Nothing is scanned in the background or on a schedule in this
  feature.
- Application bundles are presented as single items by default, since users think of an installed
  app as one thing, but a user who explicitly asks to look inside one can expand it. Bundles are
  not expanded during the initial scan; their contents are measured on demand when opened.
- Filtering operates on the results already in memory from the current scan and never triggers a
  rescan.
- Undo covers the most recent removal batch only. Older removals remain recoverable from the Trash
  by hand but are not restorable through the app.
- Inspecting an item is strictly read-only; previewing or revealing never modifies content.
- Exclusion lists and removal history are settings belonging to this machine and this user, and are
  not synchronised or shared anywhere.
- Duplicate detection operates within the scope of a single scan, not across previous scans or
  unscanned parts of the system.
- Duplicate detection skips files below 1 MB by default, as grouping them recovers negligible space
  while costing significant hashing time. The threshold is adjustable by the user, including down
  to nothing for an exhaustive pass.
- Out of scope for this feature: analysing cloud-only or not-yet-downloaded files, scanning remote
  machines, uninstalling applications, comparing one scan against another over time, and any form of
  disk repair or optimisation.
