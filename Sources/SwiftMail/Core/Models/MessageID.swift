import Foundation

/**
 A structured RFC 2822 Message-ID.

 Ensures angle-bracket formatting is always correct and provides
 structured access to the local and domain parts.

 ```swift
 let id = MessageID(localPart: "abc-123", domain: "example.com")
 print(id) // "<abc-123@example.com>"
 ```
 */
public struct MessageID: Sendable, Hashable, LosslessStringConvertible, Codable {
    /// The local part before the @
    public let localPart: String
    /// The domain part after the @
    public let domain: String

    public init(localPart: String, domain: String) {
        self.localPart = localPart
        self.domain = domain
    }

    /// Formatted with angle brackets: `<localPart@domain>`
    public var description: String {
        "<\(localPart)@\(domain)>"
    }
}

extension MessageID {
    /// Auto-generate a Message-ID with a UUID local part.
    public static func generate(domain: String) -> MessageID {
        MessageID(localPart: UUID().uuidString, domain: domain)
    }

    /// Parse a Message-ID string in `<localPart@domain>` format.
    /// Returns `nil` if the string doesn't match the expected format.
    public init?(_ string: String) {
        var s = string
        // Strip optional angle brackets
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        guard let atIndex = s.lastIndex(of: "@") else { return nil }
        let local = String(s[s.startIndex..<atIndex])
        let domain = String(s[s.index(after: atIndex)...])
        guard !local.isEmpty, !domain.isEmpty else { return nil }
        self.localPart = local
        self.domain = domain
    }
}

// MARK: - Codable (single string value)

extension MessageID {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = MessageID(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Message-ID format: \(string)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
