import Foundation

nonisolated enum DiskUtilityError: Error, Equatable {
    case toolUnavailable
    case failed(status: Int32)
    case unreadableOutput
}

/// The only place in the app that invokes `diskutil`.
///
/// The constitution's platform constraints require a capability reachable only through a
/// command-line tool to be isolated behind a single interface, to treat the tool's output as
/// untrusted and changeable, and to degrade to a stated approximation rather than reporting a
/// wrong number confidently. Callers get bytes and do their own parsing so that a parser can be
/// tested against canned output without running anything.
nonisolated protocol DiskUtilityRunning: Sendable {
    func run(_ arguments: [String]) throws -> Data
}

nonisolated struct DiskUtility: DiskUtilityRunning {
    private static let toolPath = "/usr/sbin/diskutil"

    func run(_ arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: Self.toolPath) else {
            throw DiskUtilityError.toolUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DiskUtilityError.toolUnavailable
        }

        // Drained before waiting: a plist listing every volume can exceed the pipe buffer, and
        // waiting first would deadlock against a tool blocked on a full pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiskUtilityError.failed(status: process.terminationStatus)
        }
        return data
    }
}

extension DiskUtilityRunning {
    /// Runs the tool and decodes its plist output, mapping every kind of failure onto the same
    /// error so callers have one path to degrade along.
    nonisolated func plist(_ arguments: [String]) throws -> [String: Any] {
        let data = try run(arguments)
        guard
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ),
            let dictionary = parsed as? [String: Any]
        else {
            throw DiskUtilityError.unreadableOutput
        }
        return dictionary
    }
}
