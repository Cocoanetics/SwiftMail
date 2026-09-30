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
    /// control character, is kept as ``AddressListEntry/invalid(_:)`` text.
    ///
    /// Groups keep their name and members. RFC 5322 groups hold mailboxes only,
    /// so a group nested in another, which a server only sends when it passes
    /// on an invalid header, is kept whole as invalid text rather than reshaped
    /// into something the header didn't say. So is a group holding an address
    /// the server couldn't complete.
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
                guard !group.children.contains(where: \.isGroup) else {
                    return .invalid(groupText(group))
                }
                let members = group.children.map(entry(fromEnvelope:))
                guard let mailboxes = members.map(\.mailboxes).allSingle else {
                    return .invalid(groupText(group))
                }
                return .group(name: group.groupName.stringValue.decodeMIMEHeader(), members: mailboxes)
        }
    }

    /// A group as RFC 5322 group text, `name: member, member;`, to keep as
    /// invalid text, with any nested group written inside its parent. The
    /// nesting is walked with a stack of its own rather than by recursion, so
    /// no depth a server sends can exhaust the call stack.
    private static func groupText(_ group: EmailAddressGroup) -> String {
        var text = groupOpening(group)
        var enclosing: [ArraySlice<EmailAddressListElement>] = []
        var children = group.children[...]
        var isFirst = true
        while true {
            guard let child = children.popFirst() else {
                text += ";"
                guard let rest = enclosing.popLast() else { return text }
                children = rest
                isFirst = false
                continue
            }
            text += isFirst ? " " : ", "
            isFirst = false
            if case .group(let nested) = child {
                enclosing.append(children)
                children = nested.children[...]
                text += groupOpening(nested)
                isFirst = true
            } else {
                text += AddressFormatter.string(for: entry(fromEnvelope: child), form: .display)
            }
        }
    }

    private static func groupOpening(_ group: EmailAddressGroup) -> String {
        AddressFormatter.phrase(group.groupName.stringValue.decodeMIMEHeader(), form: .display) + ":"
    }

    private static func mailboxEntry(_ address: NIOIMAPCore.EmailAddress) -> AddressListEntry {
        let name = address.personName?.stringValue.decodeMIMEHeader()
        let mailbox = address.mailbox?.stringValue ?? ""
        let host = address.host?.stringValue ?? ""
        let isComplete = !mailbox.isEmpty && isDomain(host)
            && !(mailbox + host).unicodeScalars.contains(where: AddressSyntax.isForbiddenControl)
        guard isComplete else {
            return .invalid(AddressFormatter.invalidText(name: name, address: mailbox + "@" + host))
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

private extension EmailAddressListElement {
    var isGroup: Bool {
        if case .group = self {
            return true
        }
        return false
    }
}

private extension Array where Element == [SwiftMail.EmailAddress] {
    /// The mailboxes when every entry was exactly one mailbox, else `nil`.
    var allSingle: [SwiftMail.EmailAddress]? {
        allSatisfy { $0.count == 1 } ? map { $0[0] } : nil
    }
}
