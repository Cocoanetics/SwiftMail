// AddressListEntry+Envelope.swift
// Address-list entries from an IMAP ENVELOPE, whose address syntax the server has parsed.

import Foundation
import NIOIMAPCore

extension Array where Element == AddressListEntry {
    /// The entries of an IMAP ENVELOPE address list (RFC 3501 §7.4.2).
    ///
    /// The server has already parsed the address syntax and hands over each
    /// address as display name, mailbox and host, so no text is parsed here.
    /// Display names are RFC 2047-decoded. The mailbox is the local-part's text,
    /// quoted where a dot-atom can't carry it (see
    /// ``AddressSyntax/envelopeAddrSpec(mailbox:host:)``). An address the server
    /// couldn't complete, with no mailbox, a host that isn't a domain, or a
    /// control character, is kept as ``AddressListEntry/invalid(_:)`` text. Groups keep their
    /// name and members; a group nested in another (which RFC 5322 doesn't
    /// allow) is flattened into it.
    static func entries(fromEnvelope list: [EmailAddressListElement]) -> [AddressListEntry] {
        list.map(AddressListEntry.entry(fromEnvelope:))
    }
}

extension AddressListEntry {
    /// One element of an ENVELOPE address list; see ``Swift/Array/entries(fromEnvelope:)``.
    fileprivate static func entry(fromEnvelope element: EmailAddressListElement) -> AddressListEntry {
        switch element {
            case .singleAddress(let address):
                return mailboxEntry(address)
            case .group(let group):
                let members = flattenedMembers(of: group)
                let name = group.groupName.stringValue.decodeMIMEHeader()
                guard let mailboxes = members.map(\.mailboxes).allSingle else {
                    let text = members.map { AddressFormatter.string(for: $0, form: .display) }.joined(separator: ", ")
                    return .invalid(AddressFormatter.phrase(name, form: .display) + ": " + text + ";")
                }
                return .group(name: name, members: mailboxes)
        }
    }

    /// The members of a group, with any nested group's members in its place.
    private static func flattenedMembers(of group: EmailAddressGroup) -> [AddressListEntry] {
        group.children.flatMap { child -> [AddressListEntry] in
            if case .group(let nested) = child {
                return flattenedMembers(of: nested)
            }
            return [entry(fromEnvelope: child)]
        }
    }

    private static func mailboxEntry(_ address: NIOIMAPCore.EmailAddress) -> AddressListEntry {
        let name = address.personName?.stringValue.decodeMIMEHeader()
        let mailbox = address.mailbox?.stringValue ?? ""
        let host = address.host?.stringValue ?? ""
        let isComplete = !mailbox.isEmpty && isDomain(host)
            && !(mailbox + host).unicodeScalars.contains(where: AddressSyntax.isForbiddenControl)
        guard isComplete else {
            let text = SwiftMail.EmailAddress(name: name, address: mailbox + "@" + host)
            return .invalid(AddressFormatter.string(for: text, form: .display))
        }
        let addrSpec = AddressSyntax.envelopeAddrSpec(mailbox: mailbox, host: host)
        return .mailbox(SwiftMail.EmailAddress(name: name, address: addrSpec))
    }

    /// Whether `host` is a domain: a dot-atom or a domain literal, and nothing else.
    private static func isDomain(_ host: String) -> Bool {
        var scanner = AddressScanner(host)
        guard let domain = try? scanner.readDomain() else { return false }
        return scanner.isAtEnd && domain.text == host
    }
}

private extension Array where Element == [SwiftMail.EmailAddress] {
    /// The mailboxes when every entry was exactly one mailbox, else `nil`.
    var allSingle: [SwiftMail.EmailAddress]? {
        allSatisfy { $0.count == 1 } ? map { $0[0] } : nil
    }
}
