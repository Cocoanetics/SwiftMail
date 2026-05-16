// MessageIdentifierSet.swift
// Implementation of type-safe sets for IMAP message identifiers

import Foundation
import NIOIMAPCore

// MARK: - MessageIdentifier Protocol

/// Protocol for message identifiers (UID and SequenceNumber)
public protocol MessageIdentifier: Hashable, Comparable, Sendable, Codable {
    var value: UInt32 { get }
    init(_ value: UInt32)
    static var latest: Self { get }
}

public extension MessageIdentifier {
    init(_ value: Int) {
        self.init(UInt32(value))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

// MARK: - UID Implementation

/// Represents a Unique Identifier (UID) in IMAP
public struct UID: MessageIdentifier, Sendable {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public static let latest = UID(UInt32.max)

    /// Convert to NIO UID
    func toNIO() -> NIOIMAPCore.UID {
        NIOIMAPCore.UID(rawValue: value)
    }

    /// Convert from NIO UID
    public init(nio: NIOIMAPCore.UID) {
        value = nio.rawValue
    }
}

// MARK: - Codable Implementation for UID

extension UID: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(UInt32.self)
    }
}

// MARK: - SequenceNumber Implementation

/// Represents a Sequence Number in IMAP
public struct SequenceNumber: MessageIdentifier, Sendable {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public static let latest = SequenceNumber(UInt32.max)

    /// Convert to NIO SequenceNumber
    func toNIO() -> NIOIMAPCore.SequenceNumber {
        NIOIMAPCore.SequenceNumber(rawValue: value)
    }
}

// MARK: - Codable Implementation for SequenceNumber

extension SequenceNumber: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(UInt32.self)
    }
}

// MARK: - MessageIdentifierSet Implementation

/// A type-safe set for message identifiers that provides an efficient
/// representation of non-contiguous ranges
public struct MessageIdentifierSet<Identifier: MessageIdentifier>: Sendable {
    /// The underlying Foundation IndexSet that stores the actual data
    private var indexSet: Foundation.IndexSet

    /// Creates an empty set
    public init() {
        indexSet = Foundation.IndexSet()
    }

    /// Creates a set containing the given integer
    public init(_ value: Int) {
        indexSet = Foundation.IndexSet(integer: value)
    }

    /// Creates a set containing integers in the given range
    public init(_ range: ClosedRange<Int>) {
        indexSet = Foundation.IndexSet(integersIn: range)
    }

    /// Creates a set containing integers from a lower bound to the maximum value
    public init(_ range: PartialRangeFrom<Int>) {
        // Use Int.max as the upper bound for partial ranges
        indexSet = Foundation.IndexSet(integersIn: range.lowerBound ... Int(UInt32.max))
    }

    /// Creates a set containing integers in the given ranges
    public init(ranges: ClosedRange<Int>...) {
        indexSet = Foundation.IndexSet()
        for range in ranges {
            indexSet.insert(integersIn: range)
        }
    }

    /// Creates a set from a comma-separated string like "1-3,5-10"
    public init?(string: String) {
        indexSet = Foundation.IndexSet()

        let components = string.components(separatedBy: ",")
        for component in components {
            let rangeParts = component.components(separatedBy: "-")
            if rangeParts.count == 1, let value = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)) {
                // Single value
                indexSet.insert(value)
            } else if rangeParts.count == 2,
                      let lower = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                      let upper = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                // Range
                indexSet.insert(integersIn: lower ... upper)
            } else {
                return nil // Invalid format
            }
        }
    }

    /// Creates a set containing the given identifier
    public init(_ identifier: Identifier) {
        indexSet = Foundation.IndexSet(integer: Int(identifier.value))
    }

    /// Creates a set from an array of identifiers
    public init(_ identifiers: [Identifier]) {
        indexSet = Foundation.IndexSet()
        for identifier in identifiers {
            indexSet.insert(Int(identifier.value))
        }
    }

    /// Creates a set containing identifiers in the given range
    public init(_ range: ClosedRange<Identifier>) {
        indexSet = Foundation.IndexSet(integersIn: Int(range.lowerBound.value) ... Int(range.upperBound.value))
    }

    /// Creates a set containing identifiers from a lower bound to the maximum value
    public init(_ range: PartialRangeFrom<Identifier>) {
        // Use the type's 'latest' value as the upper bound
        indexSet = Foundation.IndexSet(integersIn: Int(range.lowerBound.value) ... Int(UInt32.max))
    }

    /// Inserts the given integer into the set
    public mutating func insert(_ value: Int) {
        indexSet.insert(value)
    }

    /// Inserts the given identifier into the set
    public mutating func insert(_ identifier: Identifier) {
        indexSet.insert(Int(identifier.value))
    }

    /// Inserts integers in the given range into the set
    public mutating func insert(range: ClosedRange<Int>) {
        indexSet.insert(integersIn: range)
    }

    /// Inserts integers from a lower bound to the maximum value
    public mutating func insert(range: PartialRangeFrom<Int>) {
        indexSet.insert(integersIn: range.lowerBound ... Int.max)
    }

    /// Inserts identifiers in the given range into the set
    public mutating func insert(range: ClosedRange<Identifier>) {
        indexSet.insert(integersIn: Int(range.lowerBound.value) ... Int(range.upperBound.value))
    }

    /// Inserts identifiers from a lower bound to the maximum value
    public mutating func insert(range: PartialRangeFrom<Identifier>) {
        indexSet.insert(integersIn: Int(range.lowerBound.value) ... Int(UInt32.max))
    }

    /// Inserts integers in the given ranges into the set
    public mutating func insert(ranges: ClosedRange<Int>...) {
        for range in ranges {
            indexSet.insert(integersIn: range)
        }
    }

    /// Returns true if the set contains the given integer
    public func contains(_ value: Int) -> Bool {
        indexSet.contains(value)
    }

    /// Returns true if the set contains the given identifier
    public func contains(_ identifier: Identifier) -> Bool {
        indexSet.contains(Int(identifier.value))
    }

    /// Returns true if the set is empty
    public var isEmpty: Bool {
        indexSet.isEmpty
    }

    /// Returns the number of integers in the set
    public var count: Int {
        indexSet.count
    }

    /// Returns a view of the ranges in the set
    public var ranges: [ClosedRange<Int>] {
        indexSet.rangeView.map { $0.lowerBound ... $0.upperBound - 1 }
    }

    /// Converts the set to an array of identifiers
    public func toArray() -> [Identifier] {
        indexSet.map { Identifier(UInt32($0)) }
    }
}

// MARK: - Chunking

extension MessageIdentifierSet {
    /// Splits this set into an array of smaller sets of the given maximum size.
    ///
    /// - Parameter size: The maximum number of identifiers per chunk.
    ///   If zero or negative, returns a single chunk containing all elements.
    /// - Returns: An array of `MessageIdentifierSet` chunks.
    func chunked(size: Int) -> [MessageIdentifierSet<Identifier>] {
        guard !isEmpty else { return [] }
        guard size > 0 else { return [self] }
        guard count > size else { return [self] }

        let allIdentifiers = toArray()
        var chunks: [MessageIdentifierSet<Identifier>] = []
        var offset = 0

        while offset < allIdentifiers.count {
            let end = Swift.min(offset + size, allIdentifiers.count)
            let slice = Array(allIdentifiers[offset ..< end])
            chunks.append(MessageIdentifierSet<Identifier>(slice))
            offset = end
        }

        return chunks
    }
}

// MARK: - Type Aliases

/// A type-safe set of UIDs
public typealias UIDSet = MessageIdentifierSet<UID>

/// A type-safe set of sequence numbers
public typealias SequenceNumberSet = MessageIdentifierSet<SequenceNumber>

// MARK: - NIO Conversion Extensions

extension MessageIdentifierSet {
    /// Converts to NIO MessageIdentifierSetNonEmpty
    /// This method uses type constraints to determine the correct NIO type
    func toNIOSet<NIOType>() -> NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOType> {
        precondition(!isEmpty, "Cannot convert an empty set to NIO")

        // Create an empty NIO set
        var nioSet = NIOIMAPCore.MessageIdentifierSet<NIOType>()

        // Convert each range to a NIO range and add it to the set.
        // The Identifier/NIOType pairings are checked explicitly before each cast,
        // so the force-casts cannot fail at runtime.
        for range in ranges {
            if Identifier.self == UID.self, NIOType.self == NIOIMAPCore.UID.self {
                let startUID = NIOIMAPCore.UID(rawValue: UInt32(range.lowerBound))
                let endUID = NIOIMAPCore.UID(rawValue: UInt32(range.upperBound))
                let nioRange = NIOIMAPCore.MessageIdentifierRange(startUID ... endUID)
                // swiftlint:disable:next force_cast
                let typedRange = nioRange as! NIOIMAPCore.MessageIdentifierRange<NIOType>
                nioSet.formUnion(NIOIMAPCore.MessageIdentifierSet<NIOType>(typedRange))
            } else if Identifier.self == SequenceNumber.self, NIOType.self == NIOIMAPCore.SequenceNumber.self {
                let startSeq = NIOIMAPCore.SequenceNumber(rawValue: UInt32(range.lowerBound))
                let endSeq = NIOIMAPCore.SequenceNumber(rawValue: UInt32(range.upperBound))
                let nioRange = NIOIMAPCore.MessageIdentifierRange(startSeq ... endSeq)
                // swiftlint:disable:next force_cast
                let typedRange = nioRange as! NIOIMAPCore.MessageIdentifierRange<NIOType>
                nioSet.formUnion(NIOIMAPCore.MessageIdentifierSet<NIOType>(typedRange))
            } else {
                preconditionFailure("Unsupported type combination")
            }
        }

        return NIOIMAPCore.MessageIdentifierSetNonEmpty(set: nioSet)!
    }
}

extension MessageIdentifierSet where Identifier == UID {
    /// Creates a SwiftMail UIDSet from a NIOIMAPCore UIDSet.
    init(nio: NIOIMAPCore.UIDSet) {
        self.init()
        for nioRange in nio.ranges {
            let lower = UID(nioRange.range.lowerBound.rawValue)
            let upper = UID(nioRange.range.upperBound.rawValue)
            insert(range: lower ... upper)
        }
    }

    /// Converts to NIO MessageIdentifierSetNonEmpty for UID
    func toNIOSet() -> NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.UID>? {
        if isEmpty {
            return nil
        }

        var nioSet = NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UID>()

        for range in ranges {
            let startUID = NIOIMAPCore.UID(rawValue: UInt32(range.lowerBound))
            let endUID = NIOIMAPCore.UID(rawValue: UInt32(range.upperBound))
            let nioRange = NIOIMAPCore.MessageIdentifierRange(startUID ... endUID)
            nioSet.formUnion(NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.UID>(nioRange))
        }

        return NIOIMAPCore.MessageIdentifierSetNonEmpty(set: nioSet)
    }
}

extension MessageIdentifierSet where Identifier == SequenceNumber {
    /// Converts to NIO MessageIdentifierSetNonEmpty for SequenceNumber
    func toNIOSet() -> NIOIMAPCore.MessageIdentifierSetNonEmpty<NIOIMAPCore.SequenceNumber>? {
        if isEmpty {
            return nil
        }

        var nioSet = NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.SequenceNumber>()

        for range in ranges {
            let startSeq = NIOIMAPCore.SequenceNumber(rawValue: UInt32(range.lowerBound))
            let endSeq = NIOIMAPCore.SequenceNumber(rawValue: UInt32(range.upperBound))
            let nioRange = NIOIMAPCore.MessageIdentifierRange(startSeq ... endSeq)
            nioSet.formUnion(NIOIMAPCore.MessageIdentifierSet<NIOIMAPCore.SequenceNumber>(nioRange))
        }

        return NIOIMAPCore.MessageIdentifierSetNonEmpty(set: nioSet)
    }
}

// MARK: - Example Usage

/*
 // Create a set with a single UID
 var uidSet = UIDSet(UID(1))

 // Create a set with a range of UIDs
 let rangeSet = UIDSet(UID(1)...UID(10))

 // Create a set with multiple ranges
 let multiRangeSet = UIDSet(ranges: 1...3, 5...10)

 // Create a set from a string
 if let setFromString = UIDSet(string: "1-3,5-10") {
     // Use the set
 }

 // Add a UID to the set
 uidSet.insert(UID(4))

 // Add a range of UIDs
 uidSet.insert(range: UID(5)...UID(10))

 // Convert to NIO MessageIdentifierSetNonEmpty for use with the IMAP library
 if let nioSet = uidSet.toNIOSet() {
     // Use with NIO IMAP library
 }
 */
