// MessageInfoAddressHostileInputTests.swift
// Address data a server or a caller got wrong: nested groups at any depth, and control
// characters, are kept as invalid, never reshaped into an address the source didn't name.

import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

// MARK: - Hostile sources

/// An ENVELOPE group nested 100,000 levels deep. It is kept alive for the whole
/// run: swift-nio-imap releases its nested groups recursively, which overflows a
/// 512 KiB thread stack at about 1,300 levels (apple/swift-nio-imap#859), so only
/// a structure that is never released can show that SwiftMail itself doesn't recurse.
private let deeplyNestedGroup: EmailAddressListElement = {
    var element = EmailAddressListElement.singleAddress(envelopeAddress(nil, "a"))
    for level in 0..<100_000 {
        let group = EmailAddressGroup(groupName: ByteBuffer(string: "G\(level)"), sourceRoot: nil, children: [element])
        element = .group(group)
    }
    return element
}()

private func envelopeAddress(
    _ name: String?, _ mailbox: String, host: String = "example.com"
) -> NIOIMAPCore.EmailAddress {
    NIOIMAPCore.EmailAddress(
        personName: name.map { ByteBuffer(string: $0) }, sourceRoot: nil,
        mailbox: ByteBuffer(string: mailbox), host: ByteBuffer(string: host)
    )
}

extension MessageInfoAddressTests {
    @Test("A group nested in another is kept as invalid text, at any depth and without recursion")
    func nestedEnvelopeGroups() {
        let deep = [AddressListEntry].entries(fromEnvelope: [deeplyNestedGroup])
        guard case .invalid(let text) = deep.first else {
            Issue.record("a nested group was not kept as invalid text")
            return
        }
        #expect(text.hasPrefix("G99999: G99998: G99997:"))
        #expect(text.hasSuffix(" a@example.com" + String(repeating: ";", count: 100_000)))

        let sub = EmailAddressGroup(groupName: ByteBuffer(string: "Sub"), sourceRoot: nil, children: [
            .singleAddress(envelopeAddress(nil, "y")), .singleAddress(envelopeAddress(nil, "z"))
        ])
        let team = EmailAddressGroup(groupName: ByteBuffer(string: "Team"), sourceRoot: nil, children: [
            .singleAddress(envelopeAddress(nil, "x")), .group(sub), .singleAddress(envelopeAddress(nil, "w"))
        ])
        let entries = [AddressListEntry].entries(fromEnvelope: [.group(team)])
        #expect(entries == [.invalid("Team: x@example.com, Sub: y@example.com, z@example.com;, w@example.com;")])
        #expect(entries.mailboxes.isEmpty)
        // Written out and read back, the text still names no address.
        #expect(AddressParser.parseAddressList(entries.map(\.description).joined(separator: ", ")).mailboxes.isEmpty)
    }

    @Test("An ENVELOPE mailbox with a control character stays invalid everywhere it is written")
    func envelopeControlStaysInvalid() throws {
        let entries = [AddressListEntry].entries(fromEnvelope: [
            .singleAddress(envelopeAddress("Victim", "victim\u{0007}")), .singleAddress(envelopeAddress(nil, "bob"))
        ])
        #expect(entries.first == .invalid("Victim <victim\u{0007}@example.com>"))

        var header = MessageInfo(sequenceNumber: SequenceNumber(1))
        header.fromAddresses = [.mailbox(Self.alice)]
        header.toAddresses = entries
        // The text older decoders read, and an EML round trip, never promote it to a mailbox.
        #expect(header.to.flatMap(AddressParser.parseAddressList).mailboxes.map(\.address) == ["bob@example.com"])
        let reparsed = try Message(emlData: Message(header: header, parts: []).emlData()).header
        #expect(reparsed.toAddresses.mailboxes.map(\.address) == ["bob@example.com"])
        #expect(reparsed.toAddresses.first?.isInvalid == true)
    }

    @Test("A caller-built mailbox whose address holds a control never serializes as a different address")
    func structuredControlAddressIsNotPromoted() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1))
        header.fromAddresses = [.mailbox(Self.alice)]
        header.toAddresses = [.mailbox(.init(address: "victim\u{0007}@example.com")), .mailbox(Self.bob)]

        let reparsed = try Message(emlData: Message(header: header, parts: []).emlData()).header
        #expect(reparsed.toAddresses.mailboxes == [Self.bob])
        #expect(reparsed.toAddresses.first?.isInvalid == true)
    }

    @Test("An MSG address with a control character stays invalid; a name-addr in the address property is read")
    func msgAddressText() throws {
        func recipient(_ index: Int, _ name: String, _ address: String) -> CFBNode {
            let children = mapiNodes([
                .int32(.recipientType, 1), .unicode(.displayName, name), .unicode(.smtpAddress, address)
            ], isTopLevel: false)
            return .storage(name: "__recip_version1.0_#0000000\(index)", children: children)
        }
        let recipients = [
            recipient(0, "Victim", "victim\u{0007}@example.com"),
            recipient(1, "Bob", "Robert <bob@example.com>")
        ]
        let msg = CompoundFileBuilder.build(
            root: mapiNodes([.unicode(.subject, "Hallo")], isTopLevel: true, extra: recipients)
        )

        let header = try MSGParser.parse(msg).header
        #expect(header.toAddresses == [.invalid("Victim <victim\u{0007}@example.com>"), .mailbox(Self.bob)])
        #expect(header.to.flatMap(AddressParser.parseAddressList).mailboxes == [Self.bob])
    }

    @Test("MSG text that names no valid address stays invalid through the strings and EML, however it looks")
    func msgInvalidTextStaysInvalid() throws {
        // A trailing line break is no part of the address, and a display name that
        // looks like an address is still only a name.
        let recipient = CFBNode.storage(name: "__recip_version1.0_#00000000", children: mapiNodes([
            .int32(.recipientType, 1), .unicode(.displayName, "Victim"), .unicode(.smtpAddress, "victim@example.com\n")
        ], isTopLevel: false))
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.displayCc, "victim@example.com; Bob <bob@example.com>")
        ], isTopLevel: true, extra: [recipient]))

        let header = try MSGParser.parse(msg).header
        #expect(header.toAddresses == [.invalid("Victim <victim@example.com\n>")])
        #expect(header.ccAddresses == [.invalid("victim@example.com"), .invalid("Bob <bob@example.com>")])
        #expect(header.cc == ["\"victim@example.com\"", "\"Bob <bob@example.com>\""])

        // Read back from the legacy strings or from EML, every entry is the same invalid text.
        #expect(header.to.flatMap(AddressParser.parseAddressList) == header.toAddresses)
        #expect(header.cc.flatMap(AddressParser.parseAddressList) == header.ccAddresses)
        let reparsed = try Message(emlData: Message(header: header, parts: []).emlData()).header
        #expect(reparsed.toAddresses == header.toAddresses)
        #expect(reparsed.ccAddresses == header.ccAddresses)
    }
}
