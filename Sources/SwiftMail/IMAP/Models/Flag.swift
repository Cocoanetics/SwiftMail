//
//  Flag.swift
//  SwiftIMAP
//
//  Created by Oliver Drobnik on 03.03.25.
//

import Foundation
import NIOIMAPCore

/// Represents an IMAP message flag
public enum Flag: Sendable {
    case seen
    case answered
    case flagged
    case deleted
    case draft
    /// Note: Recent flag is not allowed in STORE commands
    case custom(String)

    /// Convert from a NIOIMAPCore Flag
    init(nio: NIOIMAPCore.Flag) {
        let raw = String(nio)
        switch raw.uppercased() {
            case "\\SEEN": self = .seen
            case "\\ANSWERED": self = .answered
            case "\\FLAGGED": self = .flagged
            case "\\DELETED": self = .deleted
            case "\\DRAFT": self = .draft
            default: self = .custom(raw)
        }
    }

    /// Convert to NIO Flag
    func toNIO() -> NIOIMAPCore.Flag {
        switch self {
            case .seen:
                .seen
            case .answered:
                .answered
            case .flagged:
                .flagged
            case .deleted:
                .deleted
            case .draft:
                .draft
            case let .custom(name):
                if let keyword = NIOIMAPCore.Flag.Keyword(name) {
                    .keyword(keyword)
                } else {
                    // Fallback to a safe default if the keyword is invalid
                    .keyword(NIOIMAPCore.Flag.Keyword("CUSTOM")!)
                }
        }
    }
}

// MARK: - Custom String Representation

extension Flag: CustomStringConvertible {
    public var description: String {
        switch self {
            case .seen: "seen"
            case .answered: "answered"
            case .flagged: "flagged"
            case .deleted: "deleted"
            case .draft: "draft"
            case let .custom(value): value
        }
    }
}

extension Flag: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
            case .seen: "👁️"
            case .answered: "↩️ "
            case .flagged: "🚩"
            case .deleted: "🗑️ "
            case .draft: "📝"
            case let .custom(value): value
        }
    }
}

// MARK: - Codable Implementation

extension Flag: Codable {
    /// Encoding as a simple string
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Decoding from a string
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value.lowercased() {
            case "seen": self = .seen
            case "answered": self = .answered
            case "flagged": self = .flagged
            case "deleted": self = .deleted
            case "draft": self = .draft
            default: self = .custom(value)
        }
    }
}
