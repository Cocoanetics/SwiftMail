import Foundation
import NIOIMAPCore

/// Represents the UID validity value of a mailbox.
///
/// Combined with a message UID, forms a unique 64-bit identifier across
/// mailbox lifecycle changes. When UIDVALIDITY changes, all previously
/// cached UIDs for that mailbox are invalidated.
public struct UIDValidity: Hashable, Codable, Sendable {
    /// The raw validity value.
    public let value: UInt32

    /// Creates a new UID validity value.
    public init(_ value: UInt32) {
        self.value = value
    }

    /// Creates from an integer value.
    public init(_ value: Int) {
        self.value = UInt32(value)
    }

    // MARK: - NIOIMAPCore Conversion

    /// Creates from NIOIMAPCore representation.
    internal init(nio: NIOIMAPCore.UIDValidity) {
        self.value = UInt32(nio)
    }

    /// Converts to NIOIMAPCore representation.
    internal func toNIO() -> NIOIMAPCore.UIDValidity {
        NIOIMAPCore.UIDValidity(exactly: value)!
    }

    // MARK: - Codable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(UInt32.self)
    }
}

// MARK: - CustomStringConvertible
extension UIDValidity: CustomStringConvertible {
    public var description: String {
        "\(value)"
    }
}

// MARK: - ExpressibleByIntegerLiteral
extension UIDValidity: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt32) {
        self.value = value
    }
}
