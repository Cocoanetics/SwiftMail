//
//  MailFlagColor.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 22.02.26.
//

import Foundation

/// Represents Apple Mail.app flag colors
///
/// Mail.app uses `$MailFlagBit0`, `$MailFlagBit1`, and `$MailFlagBit2` IMAP keyword flags
/// to encode the flag color (3 bits = 8 combinations, 7 colors + 1 default).
public enum MailFlagColor: String, Codable, Sendable, CaseIterable {
    /// Red (default, no color bits set)
    case red

    /// Orange ($MailFlagBit1)
    case orange

    /// Yellow ($MailFlagBit2)
    case yellow

    /// Green ($MailFlagBit0 + $MailFlagBit1)
    case green

    /// Blue ($MailFlagBit0 + $MailFlagBit2)
    case blue

    /// Purple ($MailFlagBit1 + $MailFlagBit2)
    case purple

    /// Gray ($MailFlagBit0 + $MailFlagBit1 + $MailFlagBit2)
    case gray

    /// Initialize from a set of IMAP flags (checking for `$MailFlagBit*` keywords)
    /// - Parameter flags: Array of IMAP flags
    /// - Returns: The detected Mail.app flag color, or `nil` if not flagged
    public init?(flags: [Flag]) {
        // Check if message is flagged at all
        guard flags.contains(.flagged) else {
            return nil
        }

        // Extract Mail.app color bits
        let bit0 = flags.contains(.custom("$MailFlagBit0"))
        let bit1 = flags.contains(.custom("$MailFlagBit1"))
        let bit2 = flags.contains(.custom("$MailFlagBit2"))

        // Map bit pattern to color
        switch (bit0, bit1, bit2) {
            case (false, false, false):
                self = .red
            case (false, true, false):
                self = .orange
            case (false, false, true):
                self = .yellow
            case (true, true, false):
                self = .green
            case (true, false, true):
                self = .blue
            case (false, true, true):
                self = .purple
            case (true, true, true):
                self = .gray
            case (true, false, false):
                // Standalone bit0 - not used by Mail.app, treat as red
                self = .red
        }
    }

    /// Convert to Mail.app IMAP keyword flags
    /// - Returns: Array of `$MailFlagBit*` custom flags for this color
    public var flagBits: [Flag] {
        switch self {
            case .red:
                return [] // no color bits
            case .orange:
                return [.custom("$MailFlagBit1")]
            case .yellow:
                return [.custom("$MailFlagBit2")]
            case .green:
                return [.custom("$MailFlagBit0"), .custom("$MailFlagBit1")]
            case .blue:
                return [.custom("$MailFlagBit0"), .custom("$MailFlagBit2")]
            case .purple:
                return [.custom("$MailFlagBit1"), .custom("$MailFlagBit2")]
            case .gray:
                return [.custom("$MailFlagBit0"), .custom("$MailFlagBit1"), .custom("$MailFlagBit2")]
        }
    }

    /// Emoji representation of the flag color
    public var emoji: String {
        switch self {
            case .red:      return "🚩"
            case .orange:   return "🟧"
            case .yellow:   return "🟨"
            case .green:    return "🟩"
            case .blue:     return "🟦"
            case .purple:   return "🟪"
            case .gray:     return "⬜"
        }
    }

    /// Human-readable localized name (English)
    public var displayName: String {
        switch self {
            case .red:      return "Red"
            case .orange:   return "Orange"
            case .yellow:   return "Yellow"
            case .green:    return "Green"
            case .blue:     return "Blue"
            case .purple:   return "Purple"
            case .gray:     return "Gray"
        }
    }
}

// MARK: - Equatable
extension MailFlagColor: Equatable {}

// MARK: - CustomStringConvertible
extension MailFlagColor: CustomStringConvertible {
    public var description: String {
        displayName
    }
}
