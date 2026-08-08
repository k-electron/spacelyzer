# Contract: Presentation, Filtering, and Layout

**Date**: 2026-08-08 | **Spec**: [../spec.md](../spec.md) | **Model**: [../data-model.md](../data-model.md)

Interfaces between the node store and the two views. Everything here is a pure function of the
store plus a small amount of state, which is what allows layout and filtering to be unit-tested
with no interface running.

---

## FilterEvaluator

```swift
protocol FilterEvaluator {
    func evaluate(_ filter: Filter, over store: NodeStore) -> FilterResult
}

struct FilterResult {
    let matches: NodeBitmap
    let matchCount: Int
    let combinedSize: Int64
}
```

**Contract**

- Evaluation never rescans and never touches the filesystem (FR-037, and the assumption that
  filtering works on results already in memory).
- The result is a bitmap over `NodeID`, not a list of nodes, so the treemap can test membership in
  constant time while drawing and so re-evaluation stays inside SC-009's 200 ms at a million nodes.
- An empty filter matches every node. Conditions combine conjunctively.
- A directory matches if it satisfies the conditions itself; it is additionally retained for
  structure when any descendant matches, so the outline can still show the path to a match rather
  than a flat list of orphans.
- The same `FilterResult` drives both views. Producing separate results per view would allow them
  to disagree, which FR-042 forbids.

---

## CategoryAnalyzer

```swift
protocol CategoryAnalyzer {
    func breakdown(of store: NodeStore, matching: NodeBitmap?) -> [CategoryTotal]
}
```

**Contract**

- One pass over the store, no rescan, within the 2 seconds SC-010 allows.
- Results are ranked by combined size descending (FR-044).
- Shares are computed against the total of the nodes considered, so a breakdown of a filtered
  subset sums to 100% of that subset rather than of the whole scan.
- Nodes flagged `countedElsewhere` contribute zero, preserving the count-once invariant.

---

## TreemapLayoutEngine

```swift
protocol TreemapLayoutEngine {
    func layout(
        root: NodeID,
        in rect: CGRect,
        store: NodeStore,
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

---

## SelectionCoordinator

```swift
@MainActor
protocol SelectionCoordinator: Observable {
    var selected: NodeID? { get }
    var displayedRoot: NodeID { get }

    func select(_ id: NodeID?, from origin: SelectionOrigin)
    func drill(to id: NodeID)
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
