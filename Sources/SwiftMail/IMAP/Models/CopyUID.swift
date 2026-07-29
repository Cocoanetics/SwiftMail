import Foundation
import NIOIMAPCore

/// The verified COPYUID mapping returned by the server after a UID-based COPY or MOVE operation.
///
/// When the server supports UIDPLUS (RFC 4315) and returns a `COPYUID` response code in the
/// tagged `OK`, this value carries the exact source-to-destination UID mapping in the order
/// the server provided it. When `COPYUID` is absent — either because the server doesn't
/// advertise UIDPLUS or chose not to include the code — the corresponding method returns
/// `nil` instead.
public struct CopyUID: Sendable {
    /// The UIDVALIDITY of the destination mailbox.
    ///
    /// If this value differs from a previously cached UIDVALIDITY for the destination,
    /// all previously cached UIDs for that mailbox are invalid.
    public let destinationUIDValidity: UIDValidity

    /// An ordered list of source-to-destination UID pairs.
    ///
    /// Each element maps one source UID to the UID the server assigned to the copy in the
    /// destination mailbox. The order matches the source-to-destination correspondence in
    /// the server's COPYUID response.
    public let mapping: [(source: UID, destination: UID)]

    public init(destinationUIDValidity: UIDValidity, mapping: [(source: UID, destination: UID)]) {
        self.destinationUIDValidity = destinationUIDValidity
        self.mapping = mapping
    }
}

extension CopyUID {
    /// Converts from NIOIMAPCore's `ResponseCodeCopy`, expanding UID ranges into individual pairs.
    /// Throws `IMAPError.commandFailed` if the source and destination cardinalities do not match,
    /// or if any range is implausibly large (guard against malformed server responses).
    internal init(nio data: NIOIMAPCore.ResponseCodeCopy) throws {
        let validity = UIDValidity(nio: data.destinationUIDValidity)

        let sourceUIDs = try Self.expand(data.sourceUIDs)
        let destinationUIDs = try Self.expand(data.destinationUIDs)

        guard sourceUIDs.count == destinationUIDs.count else {
            throw IMAPError.commandFailed(
                "COPYUID source/destination cardinality mismatch: \(sourceUIDs.count) vs \(destinationUIDs.count)"
            )
        }

        self.destinationUIDValidity = validity
        self.mapping = zip(sourceUIDs, destinationUIDs).map { (source: $0, destination: $1) }
    }

    private static let maxExpandedUIDs = 1_000_000

    private static func expand(_ ranges: [NIOIMAPCore.UIDRange]) throws -> [UID] {
        var result: [UID] = []
        for nioRange in ranges {
            let lower = nioRange.range.lowerBound.rawValue
            let upper = nioRange.range.upperBound.rawValue
            guard lower <= upper else {
                throw IMAPError.commandFailed("COPYUID contains an invalid UID range")
            }
            let rangeCount = Int(upper - lower) + 1
            // Guard against the cumulative expansion exceeding the cap — many small ranges
            // can otherwise trigger the same allocation blow-up as a single oversized range.
            guard result.count + rangeCount <= maxExpandedUIDs else {
                throw IMAPError.commandFailed("COPYUID expansion exceeds \(maxExpandedUIDs) UIDs")
            }
            for raw in lower...upper {
                result.append(UID(raw))
            }
        }
        return result
    }
}
