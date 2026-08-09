import Foundation
import Testing
@testable import Spacelyzer

private func file(
    _ name: String,
    _ size: Int64,
    category: FileCategory = .other,
    modified: Date = Date(timeIntervalSince1970: 1_000_000)
) -> ScannedItem {
    ScannedItem(
        name: name, kind: .file, category: category,
        ownSize: size, cumulativeSize: size, itemCount: 1,
        created: modified, modified: modified, accessed: modified,
        countedElsewhere: false, unreadable: false, hasUnexpandedContents: false, children: []
    )
}

private func folder(_ name: String, children: [ScannedItem]) -> ScannedItem {
    ScannedItem(
        name: name, kind: .directory, category: .folder,
        ownSize: 0,
        cumulativeSize: children.reduce(0) { $0 + $1.cumulativeSize },
        itemCount: children.reduce(1) { $0 + $1.itemCount },
        created: .distantPast, modified: .distantPast, accessed: .distantPast,
        countedElsewhere: false, unreadable: false, hasUnexpandedContents: false,
        children: children
    )
}

private let tree = folder("root", children: [
    folder("photos", children: [
        file("holiday.jpg", 5_000, category: .image),
        file("portrait.PNG", 3_000, category: .image),
    ]),
    folder("code", children: [
        file("main.swift", 900, category: .code),
        file("README.md", 100, category: .document),
    ]),
    file("archive.zip", 10_000, category: .archive),
])

@Suite("Filtering")
struct FilterEvaluatorTests {

    private func evaluate(_ filter: Filter, over item: ScannedItem = tree) -> FilterResult {
        FilterEvaluator().evaluate(filter, over: item, rootPath: "/scan")
    }

    @Test("Name matching ignores letter case and needs no rescan")
    func nameFilter() {
        var filter = Filter()
        filter.text = "HOLIDAY"

        let result = evaluate(filter)

        #expect(result.matches == ["/scan/photos/holiday.jpg"])
        #expect(result.matchCount == 1)
        #expect(result.combinedSize == 5_000)
    }

    @Test("Category matching selects every item of that kind")
    func categoryFilter() {
        var filter = Filter()
        filter.categories = [.image]

        let result = evaluate(filter)

        #expect(result.matchCount == 2)
        #expect(result.combinedSize == 8_000)
    }

    @Test("Extension matching is case insensitive and ignores the dot the user typed")
    func extensionFilter() {
        var filter = Filter()
        filter.fileExtensions = ["png"]

        let result = evaluate(filter)

        // The file is named .PNG; the filter was given png.
        #expect(result.matches == ["/scan/photos/portrait.PNG"])
        #expect(Filter.normalizedExtension(".JPG") == "jpg")
        #expect(Filter.normalizedExtension("  ") == nil)
    }

    @Test("A dotfile is not treated as being all extension")
    func dotfilesHaveNoExtension() {
        #expect(Filter.fileExtension(of: ".gitignore") == nil)
        #expect(Filter.fileExtension(of: "notes") == nil)
        #expect(Filter.fileExtension(of: "archive.tar.gz") == "gz")
    }

    @Test("Size matching takes a floor, a ceiling, or both")
    func sizeFilter() {
        var floor = Filter()
        floor.minimumSize = 4_000
        // The folders qualify too, which is the point: someone hunting for space wants to be told
        // that a folder is large, not only its individual files.
        #expect(evaluate(floor).matches.contains("/scan/archive.zip"))
        #expect(evaluate(floor).matches.contains("/scan/photos"))

        var ceiling = Filter()
        ceiling.maximumSize = 1_000
        #expect(evaluate(ceiling).matches == ["/scan/code/main.swift", "/scan/code/README.md"])

        var band = Filter()
        band.minimumSize = 1_000
        band.maximumSize = 6_000
        #expect(evaluate(band).matches.contains("/scan/photos/holiday.jpg"))
        #expect(evaluate(band).matches.contains("/scan/archive.zip") == false)
    }

    @Test("Date matching covers a range")
    func dateFilter() {
        let recent = file("new.bin", 10, modified: Date(timeIntervalSince1970: 2_000_000))
        let subject = folder("root", children: [recent, file("old.bin", 10)])

        var filter = Filter()
        filter.modifiedAfter = Date(timeIntervalSince1970: 1_500_000)

        #expect(evaluate(filter, over: subject).matches == ["/scan/new.bin"])

        var before = Filter()
        before.modifiedBefore = Date(timeIntervalSince1970: 1_500_000)
        #expect(evaluate(before, over: subject).matches.contains("/scan/old.bin"))
        #expect(evaluate(before, over: subject).matches.contains("/scan/new.bin") == false)
    }

    @Test("Combined filters intersect rather than accumulate")
    func filtersCombine() {
        var filter = Filter()
        filter.categories = [.image]
        filter.minimumSize = 4_000

        let result = evaluate(filter)

        // Both conditions, not either: the 3 KB image is out.
        #expect(result.matches == ["/scan/photos/holiday.jpg"])
        #expect(result.matchCount == 1)
        #expect(result.combinedSize == 5_000)
    }

    @Test("A folder is kept for structure when something inside it matches")
    func ancestorsAreRetained() {
        var filter = Filter()
        filter.text = "main"

        let result = evaluate(filter)

        // Only the file matches, but the outline still needs the way down to it.
        #expect(result.matches == ["/scan/code/main.swift"])
        #expect(result.retained.contains("/scan"))
        #expect(result.retained.contains("/scan/code"))
        #expect(result.retained.contains("/scan/photos") == false)
    }

    @Test("A matching folder and its matching contents are counted once")
    func nestedMatchesAreNotDoubleCounted() {
        var filter = Filter()
        filter.text = "o"

        let result = evaluate(filter)

        // "root", "photos", "holiday.jpg", "portrait.PNG", and "code" all contain an o. Summing
        // their cumulative sizes would count the whole tree several times over.
        #expect(result.combinedSize == tree.cumulativeSize)
    }

    @Test("An empty filter is recognised as asking nothing")
    func emptyFilterIsEmpty() {
        #expect(Filter().isEmpty)

        var whitespace = Filter()
        whitespace.text = "   "
        #expect(whitespace.isEmpty)

        var real = Filter()
        real.minimumSize = 1
        #expect(real.isEmpty == false)
    }

    @Test("A filter matching nothing says so rather than returning everything")
    func noMatchesIsDistinctFromNoFilter() {
        var filter = Filter()
        filter.text = "nothing here has this name"

        let result = evaluate(filter)

        #expect(result.isEmpty)
        #expect(result.matchCount == 0)
        #expect(result.combinedSize == 0)
        #expect(result.retained.isEmpty)
    }
}

@Suite("Category breakdown")
struct CategoryAnalyzerTests {

    @Test("Totals reconcile with the scan and rank by size")
    func totalsReconcileAndRank() throws {
        let breakdown = CategoryAnalyzer().breakdown(of: tree, rootPath: "/scan")

        // Own sizes add up to what the scan measured; cumulative ones would count folders twice.
        #expect(breakdown.reduce(0) { $0 + $1.bytes } == tree.cumulativeSize)

        let first = try #require(breakdown.first)
        #expect(first.category == .archive)
        #expect(first.bytes == 10_000)

        #expect(breakdown.map(\.bytes) == breakdown.map(\.bytes).sorted(by: >))
        #expect(abs(breakdown.reduce(0.0) { $0 + $1.share } - 1) < 0.0001)
    }

    @Test("Folders contribute nothing of their own")
    func foldersDoNotAppear() {
        let breakdown = CategoryAnalyzer().breakdown(of: tree, rootPath: "/scan")

        // Directories carry no size of their own, so a Folders row would always read zero.
        #expect(breakdown.contains { $0.category == .folder } == false)
    }

    @Test("Counts are per item, not per byte")
    func itemCountsAreCorrect() throws {
        let breakdown = CategoryAnalyzer().breakdown(of: tree, rootPath: "/scan")
        let images = try #require(breakdown.first { $0.category == .image })

        #expect(images.itemCount == 2)
        #expect(images.bytes == 8_000)
    }

    @Test("A breakdown of a filtered subset sums to that subset")
    func filteredBreakdownIsSelfContained() {
        var filter = Filter()
        filter.categories = [.image]
        let result = FilterEvaluator().evaluate(filter, over: tree, rootPath: "/scan")

        let breakdown = CategoryAnalyzer().breakdown(
            of: tree, rootPath: "/scan", matching: result.matches
        )

        #expect(breakdown.count == 1)
        #expect(breakdown[0].category == .image)
        #expect(breakdown[0].bytes == 8_000)
        #expect(abs(breakdown[0].share - 1) < 0.0001)
    }

    @Test("Data counted elsewhere is not counted again here")
    func hardLinkedDataContributesOnce() {
        var alias = file("alias.zip", 10_000, category: .archive)
        alias.countedElsewhere = true
        let subject = folder("root", children: [file("real.zip", 10_000, category: .archive), alias])

        let breakdown = CategoryAnalyzer().breakdown(of: subject, rootPath: "/scan")

        #expect(breakdown.count == 1)
        #expect(breakdown[0].bytes == 10_000)
        #expect(breakdown[0].itemCount == 1)
    }
}
