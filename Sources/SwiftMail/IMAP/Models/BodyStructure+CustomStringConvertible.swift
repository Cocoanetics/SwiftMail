// BodyStructure+CustomStringConvertible.swift
// Extension to provide a human-readable representation of message body structures

import Foundation
@preconcurrency import NIOIMAPCore

extension NIOIMAPCore.BodyStructure: @retroactive CustomStringConvertible {
    public var description: String {
        // Build the tree representation without part numbers first
        var lines = [String]()
        buildTreeRepresentation(into: &lines, indent: "", isLast: true, partPath: [], includePartNumbers: true)
        return lines.joined(separator: "\n")
    }

    /// Build a tree representation of the body structure
    /// - Parameters:
    ///   - lines: Array to store the formatted lines
    ///   - indent: Current indentation string
    ///   - isLast: Whether this is the last item at the current level
    ///   - partPath: Current part path (for numbering)
    ///   - includePartNumbers: Whether to include part numbers in the output
    private func buildTreeRepresentation(
        into lines: inout [String],
        indent: String,
        isLast: Bool,
        partPath: [Int],
        includePartNumbers: Bool
    ) {
        let connector = isLast ? "└── " : "├── "
        let childIndent = indent + (isLast ? "    " : "│   ")

        // Format this node
        let (contentType, _) = formatDescription(partPath: partPath)
        let partNumberInfo = if includePartNumbers && !partPath.isEmpty {
            " ← part \(partPath.map(String.init).joined(separator: "."))"
        } else {
            ""
        }
        let wholePart = partPath.isEmpty ? " ← part: (entire message, unnumbered)" : partNumberInfo

        lines.append("\(indent)\(connector)\(contentType)\(wholePart)")

        // Process children for multipart and message/rfc822
        switch self {
            case let .multipart(multipart):
                for (index, part) in multipart.parts.enumerated() {
                    let isLastChild = index == multipart.parts.count - 1
                    let newPartPath = partPath.isEmpty ? [index + 1] : partPath + [index + 1]
                    part.buildTreeRepresentation(
                        into: &lines,
                        indent: childIndent,
                        isLast: isLastChild,
                        partPath: newPartPath,
                        includePartNumbers: includePartNumbers
                    )
                }
            case let .singlepart(part):
                // For message/rfc822, recurse into the nested body structure
                // Section numbering per RFC 3501: parts within message/rfc822 at section N
                // are N.1, N.2, etc. Singlepart content is at N.1 (not N itself).
                if case let .message(message) = part.kind {
                    let childPartPath = partPath.isEmpty ? [1] : partPath
                    switch message.body {
                        case .multipart:
                            message.body.buildTreeRepresentation(
                                into: &lines,
                                indent: childIndent,
                                isLast: true,
                                partPath: childPartPath,
                                includePartNumbers: includePartNumbers
                            )
                        case .singlepart:
                            message.body.buildTreeRepresentation(
                                into: &lines,
                                indent: childIndent,
                                isLast: true,
                                partPath: childPartPath + [1],
                                includePartNumbers: includePartNumbers
                            )
                    }
                }
        }
    }

    /// Format a description for this body part
    /// - Parameter partPath: Current part path
    /// - Returns: A tuple with (contentType, description)
    private func formatDescription(partPath _: [Int]) -> (String, String) {
        switch self {
            case let .singlepart(part):
                let contentType = switch part.kind {
                    case let .basic(mediaType):
                        "\(mediaType.topLevel)/\(mediaType.sub)"
                    case let .text(text):
                        "text/\(text.mediaSubtype)"
                    case let .message(message):
                        "message/\(message.message)"
                }

                // Get filename if available
                var filename: String?
                if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage {
                    if let disp = dispAndLang.disposition {
                        for (key, value) in disp.parameters where key.lowercased() == "filename" {
                            filename = value
                        }
                    }
                }

                let descriptionPart = filename != nil ? " (\(filename!))" : ""
                return (contentType, descriptionPart)

            case let .multipart(multipart):
                let contentType = "multipart/\(multipart.mediaSubtype)"
                return (contentType, "")
        }
    }
}
