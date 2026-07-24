import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FetchMessageInfoHandlerTests {
    @Test
    func testSingleFetchPopulatesThreadingProperties() async throws {
        let headerBlock = """
        In-Reply-To: <root@example.com>\r
        References: <root@example.com> <child@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<reply@example.com>",
                        inReplyTo: "<root@example.com>"
                    ),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == MessageID("root@example.com"))
        #expect(infos[0].references == [MessageID("<root@example.com>")!, MessageID("<child@example.com>")!])
    }

    @Test
    func testBulkFetchPopulatesThreadingPropertiesForEachMessage() async throws {
        let firstHeader = """
        In-Reply-To: <root-a@example.com>\r
        References: <root-a@example.com>\r
        \r
        """
        let secondHeader = """
        References: <root-b@example.com> <child-b@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<reply-a@example.com>",
                        inReplyTo: "<root-a@example.com>"
                    ),
                    headerBlock: firstHeader
                ),
                fetchResponse(
                    sequenceNumber: 2,
                    envelope: envelopeAttribute(messageId: "<reply-b@example.com>"),
                    headerBlock: secondHeader
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 2)
        #expect(infos[0].inReplyTo == MessageID("root-a@example.com"))
        #expect(infos[0].references == [MessageID("<root-a@example.com>")!])
        #expect(infos[1].inReplyTo == nil)
        #expect(infos[1].references == [MessageID("<root-b@example.com>")!, MessageID("<child-b@example.com>")!])
    }

    @Test
    func testMissingThreadingHeadersStayAbsent() async throws {
        let headerBlock = """
        Subject: No thread headers here\r
        X-Test: value\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(messageId: "<loner@example.com>"),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == nil)
        #expect(infos[0].references == nil)
        #expect(infos[0].additionalFields?["subject"] == nil)
        #expect(infos[0].additionalFields?["x-test"] == "value")
    }

    @Test
    func testAdditionalFieldsArePopulated() async throws {
        let headerBlock = """
        List-ID: <announcements.example.com>\r
        List-Unsubscribe: <https://example.com/unsubscribe>\r
        X-Newsletter-ID: 12345\r
        In-Reply-To: <root@example.com>\r
        References: <root@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(
                        messageId: "<msg@example.com>",
                        inReplyTo: "<root@example.com>"
                    ),
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].inReplyTo == MessageID("root@example.com"))
        #expect(infos[0].references == [MessageID("<root@example.com>")!])
        #expect(infos[0].additionalFields?["list-id"] == "<announcements.example.com>")
        #expect(infos[0].additionalFields?["list-unsubscribe"] == "<https://example.com/unsubscribe>")
        #expect(infos[0].additionalFields?["x-newsletter-id"] == "12345")
        #expect(infos[0].additionalFields?["in-reply-to"] == nil)
        #expect(infos[0].additionalFields?["references"] == nil)
    }

    @Test
    func testParseEnvelopeDateAcceptsRFC5322() {
        let date = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 29 Apr 2026 02:14:25 +0000")
        #expect(date != nil)
    }

    @Test
    func testParseEnvelopeDateAcceptsLowercaseMonth() {
        // Issue #157: senders sometimes emit lowercase month names.
        let date = FetchMessageInfoHandler.parseEnvelopeDate("29 apr 2026 02:14:25")
        let expected = Self.makeDate(DateComponents(year: 2026, month: 4, day: 29, hour: 2, minute: 14, second: 25))
        #expect(date == expected)
    }

    @Test
    func testParseEnvelopeDateAcceptsLowercaseWeekday() {
        let date = FetchMessageInfoHandler.parseEnvelopeDate("wed, 29 Apr 2026 02:14:25 +0000")
        let expected = Self.makeDate(DateComponents(year: 2026, month: 4, day: 29, hour: 2, minute: 14, second: 25))
        #expect(date == expected)
    }

    @Test
    func testParseEnvelopeDateStripsTrailingComment() {
        let date = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 29 Apr 2026 02:14:25 +0000 (UTC)")
        #expect(date != nil)
    }

    @Test
    func testParseEnvelopeDateRejectsGarbage() {
        let date = FetchMessageInfoHandler.parseEnvelopeDate("not a date")
        #expect(date == nil)
    }

    @Test
    func testParseEnvelopeDateRejectsOutOfRangeDay() {
        // Strict parsing must reject impossible day numbers rather than rolling
        // them forward into a different valid date.
        let date = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 99 Apr 2026 02:14:25 +0000")
        #expect(date == nil)
    }

    @Test
    func testParseEnvelopeDateAcceptsNamedUSTimeZones() {
        // RFC 5322 §4.3 obsolete named US time zones — common in historical mailboxes.
        let est = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 31 Jan 2018 15:02:22 EST")
        let estExpected = Self.makeDate(DateComponents(year: 2018, month: 1, day: 31, hour: 20, minute: 2, second: 22))
        #expect(est == estExpected)

        let pst = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 31 Jan 2018 15:02:22 PST")
        let pstExpected = Self.makeDate(DateComponents(year: 2018, month: 1, day: 31, hour: 23, minute: 2, second: 22))
        #expect(pst == pstExpected)

        let gmt = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 31 Jan 2018 15:02:22 GMT")
        let gmtExpected = Self.makeDate(DateComponents(year: 2018, month: 1, day: 31, hour: 15, minute: 2, second: 22))
        #expect(gmt == gmtExpected)
    }

    @Test
    func testParseEnvelopeDateLeavesUnknownZoneTokensAlone() {
        // Unknown trailing tokens shouldn't be rewritten — falls through to format trial and fails.
        let date = FetchMessageInfoHandler.parseEnvelopeDate("Wed, 31 Jan 2018 15:02:22 ZZT")
        #expect(date == nil)
    }

    @Test
    func testHeaderFieldsStreamingPopulatesAdditionalFieldsAndReferences() async throws {
        // BODY[HEADER.FIELDS (...)] uses a different streaming kind than BODY[HEADER];
        // the handler must collect both so HEADER.FIELDS-targeted fetches still parse.
        let headerBlock = """
        List-Unsubscribe: <https://example.com/unsubscribe>\r
        List-ID: <announcements.example.com>\r
        References: <root@example.com> <child@example.com>\r
        \r
        """

        let infos = try await executeFetch(
            [
                fetchResponse(
                    sequenceNumber: 1,
                    envelope: envelopeAttribute(messageId: "<msg@example.com>"),
                    headerFields: ["List-Unsubscribe", "List-ID", "References"],
                    headerBlock: headerBlock
                ),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].additionalFields?["list-unsubscribe"] == "<https://example.com/unsubscribe>")
        #expect(infos[0].additionalFields?["list-id"] == "<announcements.example.com>")
        #expect(infos[0].references == [MessageID("<root@example.com>")!, MessageID("<child@example.com>")!])
    }

    // MARK: - Structured Envelope Addresses

    @Test
    func testStructuredAddressPopulatesFromAndTo() async throws {
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: "Alice Example", mailbox: "alice", host: "example.com")],
            to: [
                imapAddress(name: "Bob Example", mailbox: "bob", host: "example.com"),
                imapAddress(name: nil, mailbox: "carol", host: "example.com")
            ]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].fromAddress == EmailAddress(name: "Alice Example", address: "alice@example.com"))
        #expect(infos[0].toAddresses == [
            EmailAddress(name: "Bob Example", address: "bob@example.com"),
            EmailAddress(name: nil, address: "carol@example.com")
        ])
    }

    @Test
    func testStructuredFromAddressDecodesRFC2047DisplayName() async throws {
        // Same encoded-word ("Täglicher Bericht") used by EMLTests.testRFC2047Subject,
        // here applied to a personName instead of a Subject header.
        let encodedName = "=?UTF-8?B?VMOkZ2xpY2hlciBCZXJpY2h0?="
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: encodedName, mailbox: "alice", host: "example.com")]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].fromAddress?.name == "Täglicher Bericht")
        // The legacy string decodes the same encoded word via the same helper -
        // the structured field isn't decoding it differently.
        #expect(infos[0].from == "\"Täglicher Bericht\" <alice@example.com>")
    }

    @Test
    func testStructuredToAddressesFlattenGroupsWithoutSyntheticEntry() async throws {
        let groupAddresses = [
            imapAddress(name: nil, mailbox: "Team", host: nil), // group start
            imapAddress(name: nil, mailbox: "alice", host: "x.com"),
            imapAddress(name: nil, mailbox: "bob", host: "x.com"),
            imapAddress(name: nil, mailbox: nil, host: nil) // group end
        ]
        let envelope = envelopeWithAddresses(to: groupAddresses)

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        // Flattened to the two members - no synthetic "Team" entry.
        #expect(infos[0].toAddresses == [
            EmailAddress(name: nil, address: "alice@x.com"),
            EmailAddress(name: nil, address: "bob@x.com")
        ])
    }

    @Test
    func testStructuredAddressDropsAndNormalisesMalformedEntries() async throws {
        // IMAP represents "field absent" with NIL, distinct from "field present but
        // empty" (""). A NIL host is reserved by the wire grammar as a group
        // boundary marker, so these malformed single addresses use an empty string
        // host/mailbox rather than NIL to exercise structuredAddress's own
        // isEmpty-based branching without being reinterpreted as a group.
        let ccAddresses = [
            imapAddress(name: nil, mailbox: "devnull", host: ""), // mailbox, no host
            imapAddress(name: nil, mailbox: "", host: "example.com"), // host, no mailbox
            imapAddress(name: nil, mailbox: "", host: "") // neither - dropped
        ]
        let envelope = envelopeWithAddresses(cc: ccAddresses)

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].ccAddresses == [
            EmailAddress(name: nil, address: "devnull"),
            EmailAddress(name: nil, address: "@example.com")
        ])
    }

    @Test
    func testLegacyFromAndToStringsAreUnchangedByStructuredAddresses() async throws {
        // formatAddress (which produces from/to/cc/bcc) is untouched by the
        // structured-address addition - this pins its exact output so the new
        // fields can be seen to be additive, not a replacement.
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: "Alice Example", mailbox: "alice", host: "example.com")],
            to: [
                imapAddress(name: nil, mailbox: "bob", host: "example.com"),
                imapAddress(name: nil, mailbox: "Team", host: nil), // group start
                imapAddress(name: nil, mailbox: "carol", host: "example.com"),
                imapAddress(name: nil, mailbox: nil, host: nil) // group end
            ]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].from == "\"Alice Example\" <alice@example.com>")
        #expect(infos[0].to == ["bob@example.com", "Team: carol@example.com"])
    }

    /// Build a `Date` from explicit Y/M/D + H/M/S components, anchored to UTC.
    /// Folded into a single `DateComponents` parameter so the helper signature
    /// stays under the 6-parameter swiftlint limit while keeping call sites
    /// readable via the labelled `DateComponents` initializer.
    private static func makeDate(_ components: DateComponents) -> Date? {
        var resolved = components
        resolved.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: resolved)
    }

    private func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
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

    private func fetchResponse(
        sequenceNumber: Int,
        envelope: String,
        headerBlock: String
    ) -> String {
        let count = headerBlock.utf8.count
        return "* \(sequenceNumber) FETCH (ENVELOPE \(envelope) BODY[HEADER] {\(count)}\r\n"
            + "\(headerBlock))\r\n"
    }

    private func fetchResponse(
        sequenceNumber: Int,
        envelope: String,
        headerFields: [String],
        headerBlock: String
    ) -> String {
        let fieldsList = headerFields.joined(separator: " ")
        let count = headerBlock.utf8.count
        return "* \(sequenceNumber) FETCH (ENVELOPE \(envelope)"
            + " BODY[HEADER.FIELDS (\(fieldsList))] {\(count)}\r\n"
            + "\(headerBlock))\r\n"
    }

    private func envelopeAttribute(messageId: String, inReplyTo: String? = nil) -> String {
        let inReplyToValue = inReplyTo.map { "\"\($0)\"" } ?? "NIL"
        return "(NIL NIL NIL NIL NIL NIL NIL NIL \(inReplyToValue) \"\(messageId)\")"
    }

    /// Build an ENVELOPE literal with explicit from/to/cc/bcc address lists, for
    /// tests exercising `structuredAddress`. Sender/reply-to are left NIL.
    private func envelopeWithAddresses(
        subject: String = "Test",
        from: [String] = [],
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        messageId: String = "<msg@example.com>"
    ) -> String {
        "(NIL \"\(subject)\" \(addressList(from)) NIL NIL \(addressList(to)) \(addressList(cc)) \(addressList(bcc)) NIL \"\(messageId)\")"
    }

    /// Render an IMAP addr-list: `NIL` when empty, else the addresses concatenated
    /// with no separator (matching how a real server encodes ENVELOPE addresses).
    private func addressList(_ addresses: [String]) -> String {
        addresses.isEmpty ? "NIL" : "(\(addresses.joined()))"
    }

    /// Render a single IMAP `address` structure: `(name adl mailbox host)`.
    ///
    /// `nil` renders as `NIL` (field absent); a non-nil `String` (including `""`)
    /// renders as a quoted string (field present, possibly empty). This distinction
    /// matters because the wire grammar treats a `NIL` host as a group start/end
    /// marker, so malformed-but-present addresses must use `""`, not `nil`, to be
    /// parsed as ordinary single addresses rather than group boundaries.
    private func imapAddress(name: String?, mailbox: String?, host: String?) -> String {
        let nameField = name.map { "\"\($0)\"" } ?? "NIL"
        let mailboxField = mailbox.map { "\"\($0)\"" } ?? "NIL"
        let hostField = host.map { "\"\($0)\"" } ?? "NIL"
        return "(\(nameField) NIL \(mailboxField) \(hostField))"
    }
}
