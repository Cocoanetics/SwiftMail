// AddressListEntry.swift
// One element of an RFC 5322 address list: a mailbox, a group, or invalid text.

import Foundation

/// One element of an address field such as `To`, `Cc`, `Bcc` or `Reply-To`
/// (RFC 5322 §3.4): a single mailbox, a named group of mailboxes, or text that
/// is not a valid address.
///
/// Its ``description`` is RFC 5322 text for a header field, and ``init(_:)``
/// reads that text back into the identical value, so an entry survives the
/// round trip through its string form:
///
/// ```swift
/// let team = AddressListEntry("Team: alice@example.com, Bob <bob@example.com>;")
/// // .group(name: "Team", members: [alice@example.com, Bob <bob@example.com>])
/// ```
public enum AddressListEntry: Hashable, Codable, Sendable {
    /// A single mailbox, such as `Jane Doe <jane@example.com>`.
    case mailbox(EmailAddress)

    /// A named group of mailboxes, such as `Team: alice@example.com, bob@example.com;`.
    /// A group may have no members, as in `undisclosed-recipients:;`.
    case group(name: String, members: [EmailAddress])

    /// Text that is not a valid address. It is kept, never dropped or repaired,
    /// so that a malformed field is never silently shortened or read as a
    /// different address.
    case invalid(String)
}

public extension AddressListEntry {
    /// The mailboxes this entry names: the mailbox itself, the members of a
    /// group, or none for invalid text.
    var mailboxes: [EmailAddress] {
        switch self {
            case .mailbox(let address):
                return [address]
            case .group(_, let members):
                return members
            case .invalid:
                return []
        }
    }
}

public extension Array where Element == AddressListEntry {
    /// Every mailbox in the list, with groups flattened to their members and
    /// invalid entries left out.
    var mailboxes: [EmailAddress] {
        flatMap(\.mailboxes)
    }
}

extension AddressListEntry: LosslessStringConvertible {
    /// Parses text that is exactly one address-list element (see
    /// ``AddressParser``). Text that is not a valid address yields
    /// ``invalid(_:)``; empty text, or text holding several elements, yields `nil`.
    ///
    /// - Parameter description: The text of one mailbox or group.
    public init?(_ description: String) {
        let entries = AddressParser.parseAddressList(description)
        guard entries.count == 1, let entry = entries.first else { return nil }
        self = entry
    }

    /// The entry as RFC 5322 text for a header field, which ``init(_:)`` reads
    /// back to this entry. Display names are written the way
    /// ``EmailAddress/description`` writes them. Invalid text is written as it
    /// is when that reads back as the same text. Otherwise, as when it holds a
    /// control character or would read back as an address, it is written as
    /// encoded-words, which read back as the same invalid text and never as an
    /// address.
    public var description: String {
        AddressFormatter.string(for: self, form: .header)
    }
}

// MARK: - Codable

extension AddressListEntry {
    private enum CodingKeys: String, CodingKey {
        case mailbox
        case group
        case invalid
    }

    private enum GroupCodingKeys: String, CodingKey {
        case name
        case members
    }

    /// Decodes an entry from an object with one key naming its kind:
    /// `{"mailbox": {"name": …, "address": …}}`,
    /// `{"group": {"name": …, "members": […]}}` or `{"invalid": "…"}`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let address = try container.decodeIfPresent(EmailAddress.self, forKey: .mailbox) {
            self = .mailbox(address)
        } else if container.contains(.group) {
            let group = try container.nestedContainer(keyedBy: GroupCodingKeys.self, forKey: .group)
            self = .group(
                name: try group.decode(String.self, forKey: .name),
                members: try group.decode([EmailAddress].self, forKey: .members)
            )
        } else if let text = try container.decodeIfPresent(String.self, forKey: .invalid) {
            self = .invalid(text)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "An address-list entry needs a \"mailbox\", \"group\" or \"invalid\" key."
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case .mailbox(let address):
                try container.encode(address, forKey: .mailbox)
            case let .group(name, members):
                var group = container.nestedContainer(keyedBy: GroupCodingKeys.self, forKey: .group)
                try group.encode(name, forKey: .name)
                try group.encode(members, forKey: .members)
            case .invalid(let text):
                try container.encode(text, forKey: .invalid)
        }
    }
}

extension AddressListEntry {
    /// Whether this is ``invalid(_:)`` text rather than a mailbox or group.
    var isInvalid: Bool {
        if case .invalid = self {
            return true
        }
        return false
    }
}
