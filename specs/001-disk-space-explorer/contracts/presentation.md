# Contract: Presentation, Filtering, and Layout

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

Interfaces between the node store and the two views. Everything here is a pure function of the
store plus a small amount of state, which is what allows layout and filtering to be unit-tested
with no interface running. Shared types are defined at the top of
[scanning.md](./scanning.md).

---

## FilterEvaluator

```swift
protocol FilterEvaluator {
    func evaluate(_ filter: Filter, over root: ScannedItem) -> FilterResult
}

struct FilterResult {
    let matches: Set<String>   // matching paths
    let matchCount: Int
    let combinedSize: Int64
}
```

**Contract**

- Evaluation never rescans and never touches the filesystem (FR-037, and the assumption that
  filtering works on results already in memory).
- The result is a set of paths rather than a second tree, so the treemap can test membership
  cheaply while drawing without duplicating the scan. Whether this reaches
  SC-009's 200 ms at a million nodes is the open performance question recorded in research R5.
- An empty filter matches every node. Conditions combine conjunctively.
- A directory matches if it satisfies the conditions itself; it is additionally retained for
  structure when any descendant matches, so the outline can still show the path to a match rather
  than a flat list of orphans.
- The same `FilterResult` drives both views. Producing separate results per view would allow them
  to disagree, which FR-042 forbids.
- Evaluation MUST be invoked off the main actor and its result delivered asynchronously. The
  function is pure, but purity does not make it cheap: SC-009 budgets 200 ms at a million nodes, so
  calling it synchronously while the user types would stall the very field they are typing into.
- A filter change arriving while an evaluation is in flight supersedes it. The superseded run is
  cancelled and its result discarded rather than delivered late over a newer one.
- This is the case Principle III's delay-then-show rule exists for. An evaluation still running
  after roughly 150 milliseconds indicates that filtering is happening; faster ones show nothing,
  because an indicator blinking on every keystroke is worse than none. Both views stay interactive
  and keep showing the previous result until the new one arrives.

---

## CategoryAnalyzer

```swift
protocol CategoryAnalyzer {
    func breakdown(of root: ScannedItem, matching: Set<String>?) -> [CategoryTotal]
}
```

**Contract**

- One pass over the store, no rescan, within the 2 seconds SC-010 allows.
- Results are ranked by combined size descending (FR-044).
- Shares are computed against the total of the nodes considered, so a breakdown of a filtered
  subset sums to 100% of that subset rather than of the whole scan.
- Nodes flagged `countedElsewhere` contribute zero, preserving the count-once invariant.
- Computed off the main actor. SC-010's 2 second budget is long enough that the breakdown is
  requested asynchronously and reports that it is working while the user waits.

---

## TreemapLayoutEngine

```swift
protocol TreemapLayoutEngine {
    func layout(
        root: ScannedItem,
        in rect: CGRect,
        minimumDrawableArea: CGFloat
    ) -> TreemapLayout
}
```

**Contract**

- Layout is a pure function. The same store, root, rectangle, and threshold always produce an
  identical result, which is what stops rectangles from reshuffling between rescans of unchanged
  data (research R6).
- Siblings are ordered by descending size with ties broken by name, so ordering never depends on
  enumeration order.
- Every child rectangle lies entirely within its parent's rectangle (FR-028).
- Areas are proportional to `cumulativeSize` as a share of the displayed root (FR-027).
- Siblings whose area falls below `minimumDrawableArea` are not dropped. They are combined into one
  `remainder` node carrying their total size and count, which is then laid out like any other
  rectangle (FR-032). A layout that silently omits nodes violates this contract.
- The engine performs no drawing and imports no view framework, so it is testable by asserting on
  geometry.
- Layout runs off the main actor and is handed to the view as an immutable snapshot. The canvas
  draws pre-computed rectangles and never lays out during a draw pass, because laying out a
  million nodes inside a draw would stall every resize (Principle III).
- A resize or a drill arriving while a layout is in flight supersedes it, the same way a filter
  change supersedes an evaluation.
- While a layout is being computed the previous one stays on screen and stays interactive, with an
  indication that work is happening. Blanking the view during relayout is a contract violation:
  it destroys the user's context to show them nothing.
- Hit testing and hover run against the spatial index of the current snapshot, which is what keeps
  them inside SC-005's 100 ms independently of how long a layout takes.

---

## SelectionCoordinator

```swift
@MainActor
protocol SelectionCoordinator: Observable {
    var selected: ScannedItem? { get }
    var displayedRoot: ScannedItem { get }

    func select(_ item: ScannedItem?, from origin: SelectionOrigin)
    func drill(to item: ScannedItem)
    func navigateOut()
}
```

**Contract**

- There is exactly one selection for a scan (FR-035). Both views read this and neither keeps its
  own copy; two synchronised selections are a contract violation, not an implementation detail.
- `select` records the origin so each view can respond appropriately without echoing: the outline
  scrolls the selection into view and expands ancestors when the origin was the treemap (FR-034),
  and the treemap highlights when the origin was the outline (FR-033). Neither may re-emit a
  selection in response to receiving one.
- Propagation completes within SC-004's 100 ms, which rules out recomputing a layout on selection
  change. Highlighting must be a draw-time property, not a relayout trigger.
- When `drill` moves to a root not containing the current selection, the selection resolves to the
  nearest containing ancestor or clears (FR-036). It never persists as an invisible selection.
- Accessibility depends on this type. The outline is the accessible equivalent of the treemap, and
  drawn treemap nodes are exposed as accessibility elements whose focus drives the same selection
  (research R7). An implementation that bypasses the coordinator for VoiceOver focus breaks the
  Principle V commitment.

---

## ItemInspector

```swift
@MainActor
protocol ItemInspector: Observable {
    var details: ItemDetails? { get }
    /// Nil when nothing is selected, which is not the same as a selection with no preview.
    var preview: PreviewState? { get }

    func inspect(path: String, in root: ScannedItem, rootPath: String)
    func clear()
    func reveal()
    func open()
}

/// Both halves of one filesystem read, so details never wait on the preview and the two can never
/// describe different items.
func resolve(item: ScannedItem, at url: URL, path: String) -> (ItemDetails, PreviewState)

enum PreviewState { case loading, ready(URL), unavailable(reason: String) }
```

**Contract**

- Details resolve from the scanned item plus a single filesystem read for the item's logical
  length, which is not stored per node. They must not wait on a preview (FR-048).
- Both the occupied and logical sizes are shown whenever they differ, so a sparse or compressed
  file reads as explicable rather than as a bug in the scanner.
- The inspector takes the selected path, not an item. Both views already agree on a path, and
  descending the measured tree from it costs a walk rather than a second look at the disk.
- Resolution is asynchronous and passes through `loading` before reaching a terminal state. SC-011
  allows up to a second for a 100 MB file, so a preview that has not arrived promptly shows that it
  is working rather than leaving a blank panel indistinguishable from a file with no preview at
  all. A preview that resolves quickly goes straight to its result without flashing a placeholder.
- `unavailable` is a first-class outcome carrying a reason, not an error (FR-050). Whether Quick
  Look would produce something worth seeing is decided before it is asked, because it answers
  almost anything with a generic icon, and an icon of a folder is not a preview. Folders, empty
  files, symbolic links, unreadable items, and items that have since moved are all refused with a
  reason. Application bundles are not: Quick Look has something real to say about one.
- Changing the selection while a preview is loading supersedes it; a late preview for a
  deselected item is discarded rather than displayed against the wrong file.
- Inspection never alters the item's contents or location (FR-049). Reveal and open hand the item
  to another process without touching it.
