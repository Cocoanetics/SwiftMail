// HeaderField.swift

import Foundation

/// A single RFC 5322 header field instance, preserving wire order and repeated values.
public struct HeaderField: Codable, Hashable, Sendable {
    /// Lowercased field name, matching the key convention used in ``MessageInfo/additionalFields``.
    public let name: String

    /// Unfolded, trimmed field value.
    public let value: String

    /// Normalizes into the stored representation, so a directly-constructed field
    /// equals — and filters alongside — the parsed field carrying the same header.
    public init(name: String, value: String) {
        self.name = Self.normalized(name: name)
        self.value = Self.normalized(value: value)
    }

    /// Decoded fields normalize too: the invariants belong to the representation,
    /// not to one construction path.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  value: try container.decode(String.self, forKey: .value))
    }

    /// Field names compare case-insensitively (RFC 5322 §3.6.8), so the stored
    /// form is lowercased — the convention `EMLParser` already applies.
    private static func normalized(name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Unfolds the way `EMLParser` does — continuation lines rejoin with a single
    /// space (RFC 5322 §2.2.3) — then trims.
    private static func normalized(value: String) -> String {
        value
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
