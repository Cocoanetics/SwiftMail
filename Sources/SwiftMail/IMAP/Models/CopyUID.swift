import Foundation
import NIOIMAPCore

/// The verified COPYUID mapping returned by the server after a UID-based COPY or MOVE operation.
///
/// When the server supports UIDPLUS (RFC 4315) and returns a `COPYUID` response code in the
/// successful `OK` response, this value carries the exact source-to-destination UID mapping
/// in the order the server provided it. When `COPYUID` is absent — either because the server
/// doesn't advertise UIDPLUS or chose not to include the code — the corresponding method
/// returns `nil` instead. Malformed, conflicting, or unverifiable evidence throws
/// ``IMAPError/malformedCopyUIDAfterTaggedOK(_:)`` rather than being collapsed into absence.
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

        let sourceUIDs = try Self.expand(data.sourceUIDs, role: "source")
        let destinationUIDs = try Self.expand(data.destinationUIDs, role: "destination")

        guard sourceUIDs.count == destinationUIDs.count else {
            throw IMAPError.commandFailed(
                "COPYUID source/destination cardinality mismatch: \(sourceUIDs.count) vs \(destinationUIDs.count)"
            )
        }

        self.destinationUIDValidity = validity
        self.mapping = zip(sourceUIDs, destinationUIDs).map { (source: $0, destination: $1) }
    }

    private static let maxExpandedUIDs = 1_000_000

    private static func expand(
        _ ranges: [NIOIMAPCore.UIDRange],
        role: String
    ) throws -> [UID] {
        var result: [UID] = []
        var seen: Set<UInt32> = []
        for nioRange in ranges {
            let lower = nioRange.range.lowerBound.rawValue
            let upper = nioRange.range.upperBound.rawValue
            // NIOIMAPCore normalizes both wire `*` and numeric 4294967295 to `.max`.
            // RFC 4315 forbids `*` in COPYUID, so fail closed on the ambiguous value rather
            // than expose wildcard evidence as verified. This conservatively rejects the
            // standards-valid numeric maximum until the parser preserves lexical provenance.
            guard lower != UInt32.max, upper != UInt32.max else {
                throw IMAPError.commandFailed(
                    "COPYUID contains an indistinguishable wildcard or maximum \(role) UID"
                )
            }
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
                guard seen.insert(raw).inserted else {
                    throw IMAPError.commandFailed("COPYUID contains duplicate \(role) UID \(raw)")
                }
                result.append(UID(raw))
            }
        }
        return result
    }

    func sourceValidationFailure<T: MessageIdentifier>(
        for identifierSet: MessageIdentifierSet<T>
    ) -> String? {
        guard T.self == UID.self else { return nil }
        // `UID.latest` encodes as unresolved `*`. Without the selected mailbox's highest UID,
        // membership cannot be proven, so fail closed rather than expose unverified evidence.
        guard !identifierSet.contains(T.latest) else {
            return "COPYUID source UIDs cannot be verified against a wildcard request"
        }
        guard let unexpected = mapping.lazy.map(\.source).first(where: { source in
            !identifierSet.contains(T(source.value))
        }) else { return nil }
        return "COPYUID contains unrequested source UID \(unexpected.value)"
    }

    func isEquivalent(to other: CopyUID) -> Bool {
        guard destinationUIDValidity == other.destinationUIDValidity,
              mapping.count == other.mapping.count
        else {
            return false
        }

        return zip(mapping, other.mapping).allSatisfy { lhs, rhs in
            lhs.source == rhs.source && lhs.destination == rhs.destination
        }
    }
}
