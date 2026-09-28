// AddressFieldIntegrationTests.swift
// Address fields from every source (EML, Outlook MSG, IMAP ENVELOPE and the ENVELOPE of an
// attached message) reach Email conversion and EML serialization through the one address
// parser: groups stay whole, quoting survives, and header values keep their Unicode text.

import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("Address fields from every source", .serialized, .timeLimit(.minutes(1)))
struct AddressFieldIntegrationTests {

    private static let alice = SwiftMail.EmailAddress(name: "Alice", address: "alice@example.com")
    private static let doeBob = SwiftMail.EmailAddress(name: "Doe, Bob", address: "bob@example.com")

    // MARK: - EML

    @Test("A group in an EML field stays whole, and its members are recipients")
    func emlGroup() throws {
        let eml = "From: Anna <anna@example.com>\r\n"
            + "To: Friends: Alice <alice@example.com>, \"Doe, Bob\" <bob@example.com>;\r\n"
            + "Subject: x\r\n\r\nBody\r\n"
        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.to == [#"Friends: Alice <alice@example.com>, "Doe, Bob" <bob@example.com>;"#])
        #expect(try Email(message: message).recipients == [Self.alice, Self.doeBob])

        let reparsed = try Message(emlData: message.emlData())
        #expect(reparsed.to.flatMap(AddressParser.parseAddressList)
            == [.group(name: "Friends", members: [Self.alice, Self.doeBob])])
    }

    @Test("Every From mailbox is serialized, and the sender is the first one")
    func emlMultipleFrom() throws {
        let eml = "From: Alice <alice@example.com>, \"Doe, Bob\" <bob@example.com>\r\n"
            + "Sender: alice@example.com\r\nTo: carol@example.com\r\nSubject: x\r\n\r\nBody\r\n"
        let message = try Message(emlData: Data(eml.utf8))

        #expect(try Email(message: message).sender == Self.alice)
        let reparsed = try Message(emlData: message.emlData())
        #expect(AddressParser.parseAddressList(reparsed.from ?? "").mailboxes == [Self.alice, Self.doeBob])
    }

    @Test("Header values keep a leading U+00A0 and a leading combining mark")
    func emlHeaderValuesKeepUnicodeText() throws {
        let eml = "Subject: \u{0301}Hello\r\nTo: \u{00A0}first@example.com\r\n"
            + "Cc: a@example.com,\r\n \u{0301}Bob <bob@example.com>\r\n\r\nBody\r\n"
        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.subject == "\u{0301}Hello")
        #expect(message.to.flatMap(AddressParser.parseAddressList)
            == [.mailbox(.init(address: "\u{00A0}first@example.com"))])
        #expect(message.cc.flatMap(AddressParser.parseAddressList).mailboxes == [
            SwiftMail.EmailAddress(address: "a@example.com"),
            SwiftMail.EmailAddress(name: "\u{0301}Bob", address: "bob@example.com")
        ])
    }

    @Test("Malformed address text is kept in the field rather than dropped")
    func emlMalformedTextIsKept() throws {
        let eml = "From: a@example.com\r\nTo: bob@example.com, first last@example.com\r\n\r\nBody\r\n"
        let message = try Message(emlData: Data(eml.utf8))

        #expect(message.to == ["bob@example.com", "first last@example.com"])
        #expect(try Email(message: message).recipients == [SwiftMail.EmailAddress(address: "bob@example.com")])
    }

    // MARK: - MSG

    @Test("An MSG recipient named with a comma is quoted, so it reads back as one mailbox")
    func msgRecipientWithComma() throws {
        let recipient = CFBNode.storage(name: "__recip_version1.0_#00000000", children: mapiNodes([
            .unicode(.displayName, "Doe, Bob"),
            .unicode(.smtpAddress, "bob@example.com"),
            .int32(.recipientType, 1)
        ], isTopLevel: false))
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.body, "Text"),
            .unicode(.senderName, "Anna Beispiel"),
            .unicode(.senderSMTPAddress, "anna@example.com")
        ], isTopLevel: true, extra: [recipient]))

        let message = try MSGParser.parse(msg)

        #expect(message.from == "Anna Beispiel <anna@example.com>")
        #expect(message.to == [#""Doe, Bob" <bob@example.com>"#])
        #expect(try Email(message: message).recipients == [Self.doeBob])
    }

    // MARK: - ENVELOPE

    @Test("ENVELOPE names with quotes, and ENVELOPE groups, give strings that read back")
    func envelopeStrings() async throws {
        let envelope = "(NIL \"Hi\" ((\"Anna\" NIL \"anna\" \"example.com\")) NIL NIL "
            + "((\"Jane \\\"JJ\\\" Doe\" NIL \"jane\" \"example.com\")"
            + "(NIL NIL \"Team\" NIL)(\"Doe, Bob\" NIL \"bob\" \"example.com\")(NIL NIL NIL NIL)"
            + "(NIL NIL \"undisclosed-recipients\" NIL)(NIL NIL NIL NIL)) NIL NIL NIL \"<m@example.com>\")"
        let infos = try await Self.executeFetch([
            "* 1 FETCH (UID 1 ENVELOPE \(envelope))\r\n",
            "A001 OK FETCH completed\r\n"
        ])
        let info = try #require(infos.first)

        #expect(info.to == [
            #""Jane \"JJ\" Doe" <jane@example.com>"#,
            #"Team: "Doe, Bob" <bob@example.com>;"#,
            "undisclosed-recipients:;"
        ])
        #expect(try Email(message: Message(header: info, parts: [])).recipients == [
            SwiftMail.EmailAddress(name: #"Jane "JJ" Doe"#, address: "jane@example.com"),
            Self.doeBob
        ])
    }

    @Test("An attached message's ENVELOPE gives strings that read back")
    func embeddedEnvelopeStrings() throws {
        func address(_ name: String?, _ mailbox: String) -> EmailAddressListElement {
            .singleAddress(NIOIMAPCore.EmailAddress(
                personName: name.map { ByteBuffer(string: $0) },
                sourceRoot: nil,
                mailbox: ByteBuffer(string: mailbox),
                host: ByteBuffer(string: "example.com")
            ))
        }
        let team = EmailAddressGroup(groupName: ByteBuffer(string: "Team"), sourceRoot: nil, children: [
            address("Doe, Bob", "bob")
        ])
        let envelope = Envelope(
            date: nil, subject: ByteBuffer(string: "Fwd"), from: [address("Anna", "anna")], sender: [], reply: [],
            to: [address(#"Jane "JJ" Doe"#, "jane"), .group(team)], cc: [], bcc: [], inReplyTo: nil, messageID: nil
        )
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let fields = BodyStructure.Fields(
            parameters: [:], id: nil, contentDescription: nil, encoding: nil, octetCount: 0
        )
        let body = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))
        let message = BodyStructure.Singlepart.Message(message: .rfc822, envelope: envelope, body: body, lineCount: 1)
        let part = BodyStructure.Singlepart(kind: .message(message), fields: fields)
        let parts = [MessagePart](BodyStructure.singlepart(part))

        let info = try #require(parts.first?.embeddedMessageInfo)
        #expect(info.to == [#""Jane \"JJ\" Doe" <jane@example.com>"#, #"Team: "Doe, Bob" <bob@example.com>;"#])
        #expect(info.to.flatMap(AddressParser.parseAddressList).mailboxes == [
            SwiftMail.EmailAddress(name: #"Jane "JJ" Doe"#, address: "jane@example.com"),
            Self.doeBob
        ])
    }

    // MARK: - Helpers

    private static func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()

        let promise = channel.eventLoop.makePromise(of: [MessageInfo].self)
        let handler = FetchMessageInfoHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for rawResponse in rawResponses {
            var buffer = channel.allocator.buffer(capacity: rawResponse.utf8.count)
            buffer.writeString(rawResponse)
            try await channel.writeInbound(buffer)
        }

        return try await promise.futureResult.get()
    }
}
