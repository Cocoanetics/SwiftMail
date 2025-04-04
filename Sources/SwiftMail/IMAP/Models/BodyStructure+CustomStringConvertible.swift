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
        let partNumberInfo = includePartNumbers && !partPath.isEmpty ? " ← part \(partPath.map(String.init).joined(separator: "."))" : ""
        let wholePart = partPath.isEmpty ? " ← part: (entire message, unnumbered)" : partNumberInfo
        
        lines.append("\(indent)\(connector)\(contentType)\(wholePart)")
        
        // Process children for multipart
        switch self {
        case .multipart(let multipart):
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
        default:
            // Singleparts don't have children to process
            break
        }
    }
    
    /// Format a description for this body part
    /// - Parameter partPath: Current part path
    /// - Returns: A tuple with (contentType, description)
    private func formatDescription(partPath: [Int]) -> (String, String) {
        switch self {
        case .singlepart(let part):
            let contentType: String
            switch part.kind {
            case .basic(let mediaType):
                contentType = "\(mediaType.topLevel)/\(mediaType.sub)"
            case .text(let text):
                contentType = "text/\(text.mediaSubtype)"
            case .message(let message):
                contentType = "message/\(message.message)"
            }
            
            // Get filename if available
            var filename: String? = nil
            if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage {
                if let disp = dispAndLang.disposition {
                    for (key, value) in disp.parameters where key.lowercased() == "filename" {
                        filename = value
                    }
                }
            }
            
            let descriptionPart = filename != nil ? " (\(filename!))" : ""
            return (contentType, descriptionPart)
            
        case .multipart(let multipart):
            let contentType = "multipart/\(multipart.mediaSubtype)"
            return (contentType, "")
        }
    }
} 
