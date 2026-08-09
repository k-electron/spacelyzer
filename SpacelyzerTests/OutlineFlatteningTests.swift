import Foundation
import Testing
@testable import Spacelyzer

private func node(
    _ name: String,
    _ size: Int64,
    children: [ScannedItem] = []
) -> ScannedItem {
    ScannedItem(
        name: name,
        kind: children.isEmpty ? .file : .directory,
        category: .other,
        ownSize: children.isEmpty ? size : 0,
        cumulativeSize: size,
        itemCount: max(1, children.count),
        created: .distantPast,
        modified: .distantPast,
        accessed: .distantPast,
        countedElsewhere: false,
        unreadable: false,
        hasUnexpandedContents: false,
        children: children
    )
}

private let tree = node("root", 1_000, children: [
    node("big", 600, children: [
        node("inner", 400, children: [node("deep.bin", 400)]),
        node("other.bin", 200),
    ]),
    node("small.bin", 400),
])

@MainActor
@Suite("Outline flattening")
struct OutlineFlatteningTests {

    private func flatten(
        expanded: Set<String>,
        fullyShown: Set<String> = [],
        order: Spacelyzer.SortOrder = .size
    ) -> [OutlineRow] {
        HierarchyOutlineView.flatten(
            tree,
            path: "/root",
            order: order,
            expanded: expanded,
            fullyShown: fullyShown
        )
    }

    @Test("A closed tree is one row")
    func closedTreeIsOneRow() {
        let rows = flatten(expanded: [])

        #expect(rows.map(\.id) == ["/root"])
        #expect(rows[0].isExpandable)
        #expect(rows[0].isExpanded == false)
    }

    @Test("Rows come out in the order they are drawn, deepest nesting included")
    func rowsFollowDisplayOrder() {
        let rows = flatten(expanded: ["/root", "/root/big", "/root/big/inner"])

        // Largest first at every level, and each folder immediately followed by its contents.
        #expect(rows.map(\.id) == [
            "/root",
            "/root/big",
            "/root/big/inner",
            "/root/big/inner/deep.bin",
            "/root/big/other.bin",
            "/root/small.bin",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 2, 1])
    }

    @Test("A closed folder costs nothing, however much is inside it")
    func closedFoldersAreNotWalked() {
        let rows = flatten(expanded: ["/root"])

        #expect(rows.map(\.id) == ["/root", "/root/big", "/root/small.bin"])
        // `big` is present but its contents are not, which is what keeps a collapsed folder of
        // fifty thousand free.
        #expect(rows.contains { $0.id == "/root/big/other.bin" } == false)
    }

    @Test("Shares are measured against the containing folder, not the whole scan")
    func sharesUseTheParent() throws {
        let rows = flatten(expanded: ["/root", "/root/big"])
        let other = try #require(rows.first { $0.id == "/root/big/other.bin" })

        #expect(other.parentTotal == 600)
    }

    @Test("A folder past the cap offers the rest rather than dropping it")
    func cappedFolderOffersTheRemainder() throws {
        let many = node(
            "root", 10_000,
            children: (0..<(HierarchyOutlineView.childLimit + 25)).map {
                node("f\($0).bin", Int64(1_000 - $0))
            }
        )
        let rows = HierarchyOutlineView.flatten(
            many, path: "/root", order: Spacelyzer.SortOrder.size, expanded: ["/root"], fullyShown: []
        )

        // Root, the cap, and one row standing for the rest.
        #expect(rows.count == HierarchyOutlineView.childLimit + 2)

        let last = try #require(rows.last)
        guard case let .more(count, bytes) = last.content else {
            Issue.record("expected a remainder row")
            return
        }
        #expect(count == 25)
        #expect(bytes > 0)
    }

    @Test("Asking to see the rest shows every child and drops the offer")
    func fullyShownFolderHasNoRemainder() {
        let many = node(
            "root", 10_000,
            children: (0..<(HierarchyOutlineView.childLimit + 25)).map {
                node("f\($0).bin", Int64(1_000 - $0))
            }
        )
        let rows = HierarchyOutlineView.flatten(
            many, path: "/root", order: Spacelyzer.SortOrder.size, expanded: ["/root"], fullyShown: ["/root"]
        )

        #expect(rows.count == HierarchyOutlineView.childLimit + 26)
        #expect(rows.contains { if case .more = $0.content { true } else { false } } == false)
    }

    @Test("The remainder row cannot be mistaken for a file of the same name")
    func remainderRowHasADistinctIdentity() {
        let many = node(
            "root", 10_000,
            children: (0..<(HierarchyOutlineView.childLimit + 1)).map {
                node("f\($0).bin", Int64(1_000 - $0))
            }
        )
        let rows = HierarchyOutlineView.flatten(
            many, path: "/root", order: Spacelyzer.SortOrder.size, expanded: ["/root"], fullyShown: []
        )

        // Selection is keyed by path, so a remainder sharing its folder's path would shadow it.
        #expect(rows.last?.id == "/root" + HierarchyOutlineView.moreRowSuffix)
        #expect(rows.last?.id != "/root")
    }

    @Test("Changing the order changes the rows")
    func orderIsHonoured() {
        let bySize = flatten(expanded: ["/root"], order: Spacelyzer.SortOrder.size).map(\.id)
        let byName = flatten(expanded: ["/root"], order: Spacelyzer.SortOrder.name).map(\.id)

        #expect(bySize == ["/root", "/root/big", "/root/small.bin"])
        #expect(byName == ["/root", "/root/big", "/root/small.bin"])

        // A case where the two genuinely differ.
        let reversed = node("root", 10, children: [node("zzz", 9), node("aaa", 1)])
        let sized = HierarchyOutlineView.flatten(
            reversed, path: "/r", order: Spacelyzer.SortOrder.size, expanded: ["/r"], fullyShown: []
        ).map(\.id)
        let named = HierarchyOutlineView.flatten(
            reversed, path: "/r", order: Spacelyzer.SortOrder.name, expanded: ["/r"], fullyShown: []
        ).map(\.id)

        #expect(sized == ["/r", "/r/zzz", "/r/aaa"])
        #expect(named == ["/r", "/r/aaa", "/r/zzz"])
    }
}
