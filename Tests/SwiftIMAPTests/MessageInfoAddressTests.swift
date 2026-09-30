// MessageInfoAddressTests.swift
// MessageInfo stores addresses once, as structured entries: every source fills them
// without a detour through text, the address strings are derived from them, and
// consumers read them, so an edit is never stale.

import Foundation
import NIO
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("MessageInfo addresses", .serialized, .timeLimit(.minutes(1)))
struct MessageInfoAddressTests {

    static let alice = SwiftMail.EmailAddress(name: "Alice", address: "alice@example.com")
    static let jane = SwiftMail.EmailAddress(name: "Doe, Jane", address: "jane@example.com")
    static let bob = SwiftMail.EmailAddress(name: "Bob", address: "bob@example.com")
    static let first = SwiftMail.EmailAddress(address: "a@example.com")
    static let second = SwiftMail.EmailAddress(address: "b@example.com")

    // MARK: - One stored copy

    @Test("The address text is derived from the entries, and setting it parses")
    func textIsDerived() {
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.toAddresses = [
            .mailbox(Self.jane), .group(name: "Team", members: [Self.first, Self.second]), .invalid("junk")
        ]
        #expect(info.to == [#""Doe, Jane" <jane@example.com>"#, "Team: a@example.com, b@example.com;", "junk"])

        info.to = ["Bob <bob@example.com>"]
        #expect(info.toAddresses == [.mailbox(Self.bob)])
        info.to.append("a@example.com")
        #expect(info.toAddresses == [.mailbox(Self.bob), .mailbox(Self.first)])
        info.to = []
        #expect(info.toAddresses.isEmpty)
    }

    @Test("Every From mailbox is kept, and read as one string")
    func fromText() {
        let text = #"Alice <alice@example.com>, "Doe, Jane" <jane@example.com>"#
        var info = MessageInfo(sequenceNumber: SequenceNumber(1), from: text)
        #expect(info.fromAddresses == [.mailbox(Self.alice), .mailbox(Self.jane)])
        #expect(info.from == text)
        info.from = nil
        #expect(info.fromAddresses.isEmpty)
        #expect(info.from == nil)
    }

    @Test("An edited field is what conversion, sending and serialization use")
    func editsAreNeverStale() throws {
        let eml = "From: Alice <alice@example.com>\r\nTo: Old <old@example.com>\r\nSubject: x\r\n\r\nBody\r\n"
        var header = try Message(emlData: Data(eml.utf8)).header
        header.to = ["New <new@example.com>"]
        header.from = "Carol <carol@example.com>"
        let message = Message(header: header, parts: [])

        let email = try Email(message: message)
        #expect(email.recipients.map(\.address) == ["new@example.com"])
        #expect(email.sender.address == "carol@example.com")
        #expect(try IMAPServer.sendDraftAddresses(from: header).recipients.map(\.address) == ["new@example.com"])
        let written = try #require(String(data: message.emlData(), encoding: .utf8))
        #expect(written.contains("new@example.com") && !written.contains("old@example.com"))
        #expect(written.contains("carol@example.com") && !written.contains("alice@example.com"))
    }

    // MARK: - Codable

    @Test("Addresses encode as entries, with their text for older readers")
    func codableRoundTrip() throws {
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.fromAddresses = [.mailbox(Self.alice)]
        info.toAddresses = [.mailbox(Self.jane), .group(name: "Team", members: []), .invalid("junk")]
        info.bccAddresses = [.mailbox(Self.bob)]

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MessageInfo.self, from: data)
        #expect(decoded.fromAddresses == info.fromAddresses)
        #expect(decoded.toAddresses == info.toAddresses)
        #expect(decoded.bccAddresses == info.bccAddresses)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["from"] as? String == "Alice <alice@example.com>")
        #expect(object["to"] as? [String] == info.to)
        #expect(object["bcc"] as? [String] == ["Bob <bob@example.com>"])
    }

    @Test("Data encoded before the entries existed decodes into them")
    func legacyDecoding() throws {
        let data = try JSONEncoder().encode(MessageInfo(sequenceNumber: SequenceNumber(1)))
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["fromAddresses", "replyToAddresses", "toAddresses", "ccAddresses", "bccAddresses"] {
            legacy.removeValue(forKey: key)
        }
        // Address text as SwiftMail used to store it: quoted ENVELOPE names, groups as one string.
        legacy["from"] = #""Alice" <alice@example.com>"#
        legacy["to"] = ["Team: a@example.com, b@example.com;", #""Doe, Jane" <jane@example.com>"#]
        legacy["cc"] = ["first last@example.com"]

        let decoded = try JSONDecoder().decode(MessageInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.fromAddresses == [.mailbox(Self.alice)])
        #expect(decoded.toAddresses == [.group(name: "Team", members: [Self.first, Self.second]), .mailbox(Self.jane)])
        #expect(decoded.ccAddresses == [.invalid("first last@example.com")])
    }

    @Test("An address-list entry encodes as one key naming its kind")
    func entryJSONShape() throws {
        let entries: [AddressListEntry] = [
            .mailbox(Self.jane), .group(name: "Team", members: [Self.first]), .invalid("junk")
        ]
        let data = try JSONEncoder().encode(entries)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.map { Array($0.keys) } == [["mailbox"], ["group"], ["invalid"]])
        #expect(try JSONDecoder().decode([AddressListEntry].self, from: data) == entries)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AddressListEntry.self, from: Data(#"{"other":1}"#.utf8))
        }
    }

    // MARK: - ENVELOPE

    @Test("ENVELOPE addresses map to entries without a detour through text")
    func envelopeEntries() async throws {
        let from = #"(("Anna" NIL "anna" "example.com")("=?UTF-8?Q?J=C3=B6rg?=" NIL "joerg" "example.com"))"#
        let reply = #"(("Reply Desk" NIL "replies" "example.com"))"#
        let to = #"(("Doe, Jane" NIL "jane" "example.com")"#
            + #"(NIL NIL "Team" NIL)(NIL NIL "a" "example.com")(NIL NIL "Sub" NIL)(NIL NIL "b" "example.com")"#
            + #"(NIL NIL NIL NIL)(NIL NIL NIL NIL)(NIL NIL "undisclosed-recipients" NIL)(NIL NIL NIL NIL))"#
        let cc = #"((NIL NIL "x" "exa mple.com")(NIL NIL "john doe" "example.com"))"#
        let envelope = "(NIL \"Hi\" \(from) NIL \(reply) \(to) \(cc) NIL NIL \"<m@example.com>\")"
        let infos = try await AddressFieldIntegrationTests.executeFetch([
            "* 1 FETCH (UID 1 ENVELOPE \(envelope))\r\n",
            "A001 OK FETCH completed\r\n"
        ])
        let info = try #require(infos.first)

        #expect(info.fromAddresses == [
            .mailbox(SwiftMail.EmailAddress(name: "Anna", address: "anna@example.com")),
            .mailbox(SwiftMail.EmailAddress(name: "Jörg", address: "joerg@example.com"))
        ])
        let replyDesk = SwiftMail.EmailAddress(name: "Reply Desk", address: "replies@example.com")
        #expect(info.replyToAddresses == [.mailbox(replyDesk)])
        #expect(info.toAddresses == [
            .mailbox(Self.jane),
            .invalid("Team: a@example.com, Sub: b@example.com;;"),
            .group(name: "undisclosed-recipients", members: [])
        ])
        #expect(info.ccAddresses == [.invalid("x@exa mple.com"), .mailbox(.init(address: #""john doe"@example.com"#))])
    }

    @Test("ENVELOPE and a header literal fill a field alike, whichever arrives first", arguments: [
        ("NIL", [AddressListEntry.mailbox(SwiftMail.EmailAddress(name: "Bob", address: "bob@example.com"))]),
        (#"((NIL NIL "undisclosed-recipients" NIL)(NIL NIL NIL NIL))"#,
         [.group(name: "undisclosed-recipients", members: [])])
    ])
    func envelopeAndHeaderOrder(_ envelopeTo: String, _ expected: [AddressListEntry]) async throws {
        let envelope = "(NIL NIL ((NIL NIL \"a\" \"example.com\")) NIL NIL \(envelopeTo) NIL NIL NIL "
            + "\"<m@example.com>\")"
        let header = "To: Bob <bob@example.com>\r\n\r\n"
        let literal = "BODY[HEADER.FIELDS (TO)] {\(header.utf8.count)}\r\n\(header)"
        let responses = [
            "* 1 FETCH (ENVELOPE \(envelope) \(literal))\r\n",
            "* 1 FETCH (\(literal) ENVELOPE \(envelope))\r\n"
        ]
        for response in responses {
            let infos = try await AddressFieldIntegrationTests.executeFetch([response, "A001 OK FETCH completed\r\n"])
            #expect(infos.first?.toAddresses == expected, "\(response.debugDescription)")
        }
    }

    @Test("An attached message's ENVELOPE fills every address field")
    func embeddedEnvelopeEntries() throws {
        func address(_ name: String?, _ mailbox: String) -> EmailAddressListElement {
            .singleAddress(NIOIMAPCore.EmailAddress(
                personName: name.map { ByteBuffer(string: $0) }, sourceRoot: nil,
                mailbox: ByteBuffer(string: mailbox), host: ByteBuffer(string: "example.com")
            ))
        }
        let envelope = Envelope(
            date: nil, subject: ByteBuffer(string: "Fwd"), from: [address("Alice", "alice")], sender: [],
            reply: [address("Bob", "bob")], to: [address("Doe, Jane", "jane")], cc: [address(nil, "a")],
            bcc: [address(nil, "b")], inReplyTo: nil, messageID: nil
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
        #expect(info.fromAddresses == [.mailbox(Self.alice)])
        #expect(info.replyToAddresses == [.mailbox(Self.bob)])
        #expect(info.toAddresses == [.mailbox(Self.jane)])
        #expect(info.ccAddresses == [.mailbox(Self.first)])
        #expect(info.bccAddresses == [.mailbox(Self.second)])
    }

    // MARK: - EML, MSG and Email

    @Test("EML address fields are read into entries")
    func emlEntries() throws {
        let eml = "From: Alice <alice@example.com>, \"Doe, Jane\" <jane@example.com>\r\n"
            + "Reply-To: Bob <bob@example.com>\r\nTo: Team: a@example.com, b@example.com;\r\n"
            + "Cc: Doe, John <john@example.com>\r\nBcc: first last@example.com\r\n\r\nBody\r\n"
        let header = try Message(emlData: Data(eml.utf8)).header

        #expect(header.fromAddresses == [.mailbox(Self.alice), .mailbox(Self.jane)])
        #expect(header.replyToAddresses == [.mailbox(Self.bob)])
        #expect(header.toAddresses == [.group(name: "Team", members: [Self.first, Self.second])])
        let john = SwiftMail.EmailAddress(name: "John", address: "john@example.com")
        #expect(header.ccAddresses == [.invalid("Doe"), .mailbox(john)])
        #expect(header.bccAddresses == [.invalid("first last@example.com")])
    }

    @Test("MSG recipients map from MAPI, whose names are never parsed")
    func msgEntries() throws {
        func recipient(_ index: Int, _ name: String?, _ address: String?, type: Int32) -> CFBNode {
            var properties: [MAPIFixtureProperty] = [.int32(.recipientType, type)]
            if let name { properties.append(.unicode(.displayName, name)) }
            if let address { properties.append(.unicode(.smtpAddress, address)) }
            let children = mapiNodes(properties, isTopLevel: false)
            return .storage(name: "__recip_version1.0_#0000000\(index)", children: children)
        }
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.senderName, "Doe, Jane"),
            .unicode(.senderSMTPAddress, "jane@example.com")
        ], isTopLevel: true, extra: [
            recipient(0, "Bob <evil@example.com>", "bob@example.com", type: 1),
            recipient(1, "b@example.com", "b@example.com", type: 1),
            recipient(2, "Nobody", nil, type: 2),
            recipient(3, "Broken", "not an address", type: 3)
        ]))

        let header = try MSGParser.parse(msg).header
        #expect(header.fromAddresses == [.mailbox(Self.jane)])
        #expect(header.toAddresses == [
            .mailbox(SwiftMail.EmailAddress(name: "Bob <evil@example.com>", address: "bob@example.com")),
            .mailbox(Self.second)
        ])
        #expect(header.ccAddresses == [.invalid("Nobody")])
        #expect(header.bccAddresses == [.invalid("Broken <not an address>")])
    }

    @Test("MSG display-name lists name no address, so they are kept as invalid text")
    func msgDisplayNames() throws {
        let msg = CompoundFileBuilder.build(root: mapiNodes([
            .unicode(.subject, "Hallo"),
            .unicode(.displayTo, "Doe, Jane; Bernd Muster")
        ], isTopLevel: true))

        #expect(try MSGParser.parse(msg).header.toAddresses == [.invalid("Doe, Jane"), .invalid("Bernd Muster")])
    }

    @Test("Email to Message copies the addresses as they are")
    func emailEntries() {
        let odd = SwiftMail.EmailAddress(name: "Bob\r\nBcc: attacker@example.com", address: "bob@example.com")
        let email = Email(
            sender: odd, recipients: [Self.jane], ccRecipients: [Self.first], bccRecipients: [Self.second],
            subject: "x", textBody: "y"
        )
        let header = Message(email: email).header

        #expect(header.fromAddresses == [.mailbox(odd)])
        #expect(header.toAddresses == [.mailbox(Self.jane)])
        #expect(header.ccAddresses == [.mailbox(Self.first)])
        #expect(header.bccAddresses == [.mailbox(Self.second)])
    }

    @Test("sendDraft reads the entries: group members are recipients, invalid text rejects the draft")
    func sendDraftEntries() throws {
        var info = MessageInfo(sequenceNumber: SequenceNumber(1))
        info.fromAddresses = [.mailbox(Self.alice)]
        info.toAddresses = [.group(name: "Team", members: [Self.first, Self.second])]
        #expect(try IMAPServer.sendDraftAddresses(from: info).recipients == [Self.first, Self.second])

        info.ccAddresses = [.invalid("junk")]
        #expect(throws: IMAPError.self) { try IMAPServer.sendDraftAddresses(from: info) }
    }
}

// MARK: - EML serialization

extension MessageInfoAddressTests {
    @Test("EML serialization can't turn one malformed structured mailbox into recipients")
    func malformedStructuredMailbox() throws {
        let malformed = "victim@example.com, attacker@example.com"
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "x")
        header.toAddresses = [.mailbox(EmailAddress(address: malformed))]

        let data = try Message(header: header, parts: []).emlData()
        let written = try #require(String(data: data, encoding: .utf8))
        #expect(!written.contains("To: " + malformed))
        #expect(try Message(emlData: data).header.toAddresses == [.invalid(malformed)])
    }

    @Test("EML serialization keeps a Reply-To that names someone other than the sender")
    func emlReplyTo() throws {
        let eml = "From: Alice <alice@example.com>\r\nReply-To: Support: Bob <bob@example.com>, a@example.com;\r\n"
            + "To: b@example.com\r\nSubject: x\r\n\r\nBody\r\n"
        let message = try Message(emlData: Data(eml.utf8))
        let written = try #require(String(data: message.emlData(), encoding: .utf8))

        #expect(written.contains("Reply-To: Support: Bob <bob@example.com>, a@example.com;\r\n"))
        #expect(try Message(emlData: message.emlData()).header.replyToAddresses == message.header.replyToAddresses)
    }

    @Test("EML serialization leaves out a Reply-To that only repeats From, as IMAP servers fill it in")
    func emlReplyToCopiedFromFrom() throws {
        var header = MessageInfo(sequenceNumber: SequenceNumber(1), subject: "x")
        header.fromAddresses = [.mailbox(Self.alice)]
        header.replyToAddresses = [.mailbox(Self.alice)]
        header.toAddresses = [.mailbox(Self.bob)]
        let written = try #require(String(data: Message(header: header, parts: []).emlData(), encoding: .utf8))
        #expect(!written.contains("Reply-To:"))

        header.replyToAddresses = []
        let withoutReplyTo = try #require(String(data: Message(header: header, parts: []).emlData(), encoding: .utf8))
        #expect(!withoutReplyTo.contains("Reply-To:"))
    }
}
