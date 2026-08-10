import CryptoKit
import Foundation

nonisolated enum DuplicateStage: Int, Sendable, CaseIterable {
    /// Gathering candidates and grouping them by the space they occupy. No file is read.
    case grouping
    /// Reading the first part of each candidate, which settles most of them.
    case sampling
    /// Reading whatever is left in full, which is the only thing that proves identity.
    case hashing

    var label: String {
        switch self {
        case .grouping: "Grouping by size"
        case .sampling: "Comparing beginnings"
        case .hashing: "Reading in full"
        }
    }
}

nonisolated struct DuplicateProgress: Sendable, Equatable {
    let stage: DuplicateStage
    let filesDone: Int
    let filesTotal: Int

    var fraction: Double {
        filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0
    }
}

nonisolated struct DuplicateReport: Sendable, Equatable {
    /// Ranked by what each would give back, largest first (FR-064).
    let sets: [DuplicateSet]
    /// How many files were eligible at all, so a run finding nothing can say what it looked at.
    let considered: Int
    /// Files skipped for being under the threshold, which is the usual reason a run finds less
    /// than someone expected.
    let belowThreshold: Int

    var recoverableSize: Int64 { sets.reduce(0) { $0 + $1.recoverableSize } }
}

/// There is no `cancelled` case, and the absence is deliberate twice over.
///
/// It could not be delivered: cancelling is something the consumer does, and a consumer that has
/// stopped listening is not there to hear about it. Nor would it carry anything — unlike a scan,
/// whose partial tree is a smaller true answer, a duplicate search that stopped part way has
/// proved nothing about the groups it did not reach. A stream that ends without `finished` ended
/// because it was stopped, and the one who stopped it already knows.
nonisolated enum DuplicateEvent: Sendable {
    case progress(DuplicateProgress)
    case finished(DuplicateReport)
}

/// Finds files whose contents are identical, in three passes that each cost more than the last
/// and each have far less to do (research R9).
///
/// Grouping by size reads nothing and eliminates almost everything. A bounded prefix settles most
/// of what survives, for one small read per file. Only what is still indistinguishable is read
/// through to the end, which is the only evidence FR-063 accepts.
nonisolated struct DuplicateFinder: Sendable {
    /// Files below this are not considered (FR-062, research R9). Zero means consider everything.
    var minimumSize: Int64 = Preferences.defaultDuplicateSizeThreshold
    /// How much of a file the sampling pass reads.
    var prefixLength = 64 * 1024
    /// How much is read at a time when hashing in full, so a large file never lands in memory
    /// whole. A scan is expected to meet files bigger than the machine's RAM.
    var chunkLength = 1 << 20

    func find(in root: ScannedItem, rootPath: String) -> AsyncStream<DuplicateEvent> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                await Self.run(
                    finder: self, root: root, rootPath: rootPath, into: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - The three passes

    private static func run(
        finder: DuplicateFinder,
        root: ScannedItem,
        rootPath: String,
        into continuation: AsyncStream<DuplicateEvent>.Continuation
    ) async {
        let (candidates, skipped) = finder.candidates(in: root, rootPath: rootPath)
        continuation.yield(
            .progress(
                DuplicateProgress(
                    stage: .grouping, filesDone: candidates.count, filesTotal: candidates.count
                )
            )
        )

        // Only sizes shared by two or more files can possibly be duplicates, and after this pass
        // most files are gone without anything having been read.
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }

        guard !Task.isCancelled else { return }

        let sampled = await finder.split(
            bySize.flatMap { $0 },
            groups: bySize,
            stage: .sampling,
            into: continuation
        ) { file in
            try Self.digest(of: file.path, limit: finder.prefixLength, chunk: finder.chunkLength)
        }

        guard !Task.isCancelled else { return }

        // A file no longer than the prefix was read to its end by the pass above, so its sample is
        // already the proof the third pass would go and fetch. Reading it again would be the same
        // bytes for the same answer, and with the threshold turned down that is most of them.
        let short = Int64(finder.prefixLength)
        let settled = sampled.filter { ($0.first?.size ?? 0) <= short }
        let unsettled = sampled.filter { ($0.first?.size ?? 0) > short }

        let deepened = await finder.split(
            unsettled.flatMap { $0 },
            groups: unsettled,
            stage: .hashing,
            into: continuation
        ) { file in
            try Self.digest(of: file.path, limit: nil, chunk: finder.chunkLength)
        }

        let sets =
            (settled + deepened)
            .compactMap { group -> DuplicateSet? in
                guard let first = group.first, group.count > 1 else { return nil }
                // Size as well as digest. Identical contents can in principle occupy different
                // amounts of space, in which case grouping by size has already separated them
                // into two sets, and two sets sharing one identity would collide in the view.
                return DuplicateSet(
                    id: "\(first.size)-\(first.digest ?? first.path)",
                    copies: group.map { DuplicateCopy(path: $0.path, size: $0.size) }
                )
            }
            // Largest recovery first, with a stable tie-break so two runs rank the same (FR-064).
            .sorted {
                $0.recoverableSize != $1.recoverableSize
                    ? $0.recoverableSize > $1.recoverableSize
                    : $0.id < $1.id
            }

        guard !Task.isCancelled else { return }
        continuation.yield(
            .finished(
                DuplicateReport(sets: sets, considered: candidates.count, belowThreshold: skipped)
            )
        )
    }

    /// Splits each group by what `fingerprint` says about its members, keeping only the subgroups
    /// that still hold more than one file.
    ///
    /// A file that cannot be read drops out rather than failing the run. It may have gone while
    /// the pass was walking, and one unreadable file is no reason to abandon what the rest proved.
    private func split(
        _ all: [Candidate],
        groups: [[Candidate]],
        stage: DuplicateStage,
        into continuation: AsyncStream<DuplicateEvent>.Continuation,
        by fingerprint: (Candidate) throws -> String
    ) async -> [[Candidate]] {
        var done = 0
        let total = all.count
        var result: [[Candidate]] = []

        for group in groups {
            var byFingerprint: [String: [Candidate]] = [:]
            for file in group {
                // Between files, as FR-066 requires. A pass cannot be interrupted mid-file
                // without leaving a partial read, and a chunk is short enough not to matter.
                if Task.isCancelled { return result }

                done += 1
                if done % Self.progressInterval == 0 || done == total {
                    continuation.yield(
                        .progress(
                            DuplicateProgress(stage: stage, filesDone: done, filesTotal: total)
                        )
                    )
                }

                guard let mark = try? fingerprint(file) else { continue }
                byFingerprint[mark, default: []].append(file.marked(mark))
            }
            result.append(contentsOf: byFingerprint.values.filter { $0.count > 1 })
        }
        return result
    }

    /// Coalesced, so a hundred thousand files do not become a hundred thousand view updates.
    private static let progressInterval = 64

    // MARK: - Candidates

    struct Candidate: Sendable {
        let path: String
        let size: Int64
        var digest: String?

        func marked(_ digest: String) -> Candidate {
            Candidate(path: path, size: size, digest: digest)
        }
    }

    /// Every regular file big enough to be worth comparing, and how many were passed over.
    ///
    /// Directories, packages, and symlinks are not files with contents to compare. Nor is anything
    /// the scan counted elsewhere: those are further paths to one hard-linked inode, which is the
    /// same bytes already, and reporting them as duplicates would promise back space that removing
    /// them cannot give.
    func candidates(in root: ScannedItem, rootPath: String) -> (files: [Candidate], skipped: Int) {
        var found: [Candidate] = []
        var skipped = 0
        var trail: [String] = []

        func walk(_ item: ScannedItem) {
            if item.kind == .file, !item.countedElsewhere {
                if item.ownSize >= minimumSize, item.ownSize > 0 {
                    var path = rootPath
                    for name in trail { path += "/" + name }
                    found.append(Candidate(path: path, size: item.ownSize, digest: nil))
                } else {
                    skipped += 1
                }
            }
            for child in item.children {
                trail.append(child.name)
                walk(child)
                trail.removeLast()
            }
        }

        walk(root)
        return (found, skipped)
    }

    // MARK: - Reading

    /// SHA-256 over a streamed read, optionally stopping after `limit` bytes.
    ///
    /// Streamed rather than `Data(contentsOf:)` because this is pointed at whatever is largest on
    /// someone's disk, and that is exactly the file that must not be loaded whole.
    static func digest(of path: String, limit: Int?, chunk: Int) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max

        while remaining > 0 {
            let want = min(chunk, remaining)
            guard let piece = try handle.read(upToCount: want), !piece.isEmpty else { break }
            hasher.update(data: piece)
            remaining -= piece.count
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
