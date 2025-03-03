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
    // Note: Recent flag is not allowed in STORE commands
    case custom(String)
    
    /// Convert to NIO Flag
    internal func toNIO() -> NIOIMAPCore.Flag {
        switch self {
        case .seen:
            return .seen
        case .answered:
            return .answered
        case .flagged:
            return .flagged
        case .deleted:
            return .deleted
        case .draft:
            return .draft
        case .custom(let name):
				if let keyword = NIOIMAPCore.Flag.Keyword(name) {
                return .keyword(keyword)
            } else {
                // Fallback to a safe default if the keyword is invalid
                return .keyword(NIOIMAPCore.Flag.Keyword("CUSTOM")!)
            }
        }
    }
}

extension Flag: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
            case .seen: return "👁️"
            case .answered: return "↩️ "
            case .flagged: return "🚩"
            case .deleted: return "🗑️ "
            case .draft: return "📝"
            case .custom(let value): return value
        }
    }
} 
