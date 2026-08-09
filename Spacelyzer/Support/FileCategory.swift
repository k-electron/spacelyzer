import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Coarse grouping used for treemap colour and for the ranked breakdown in FR-044.
nonisolated enum FileCategory: Int, Codable, CaseIterable, Sendable {
    case folder
    case image
    case video
    case audio
    case document
    case archive
    case code
    case application
    case data
    case font
    case other

    var label: String {
        switch self {
        case .folder: "Folders"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Documents"
        case .archive: "Archives"
        case .code: "Code"
        case .application: "Applications"
        case .data: "Data"
        case .font: "Fonts"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .folder: .gray
        case .image: .teal
        case .video: .purple
        case .audio: .pink
        case .document: .blue
        case .archive: .brown
        case .code: .green
        case .application: .orange
        case .data: .indigo
        case .font: .mint
        case .other: .secondary
        }
    }

    static func classify(_ type: UTType?, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .folder }
        guard let type else { return .other }

        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .application }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        // Before archive: a disk image conforms to both, and calling a .dmg an archive is closer
        // to how someone thinks about it than calling it a disk.
        if type.conforms(to: .diskImage) || type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .font) { return .font }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .code }
        if type.conforms(to: .executable) || type.conforms(to: .unixExecutable) { return .application }
        if type.conforms(to: .database) || type.conforms(to: .json) || type.conforms(to: .propertyList) {
            return .data
        }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) {
            return .document
        }
        return .other
    }
}
