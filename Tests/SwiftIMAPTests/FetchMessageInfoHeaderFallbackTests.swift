import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FetchMessageInfoHeaderFallbackTests {
    @Test
    func testHeaderFieldsPopulateStandardFieldsWithoutEnvelope() async throws {
        let headerBlock = """
        Date: Wed, 05 Aug 2026 12:13:59 -0600\r
        Subject: What's New at A-Basin This Winter?\r
        From: Arapahoe Basin <info@connect.arapahoebasin.com>\r
        To: Joel <joel@example.com>, Michelle <michelle@example.com>\r
        Cc: Team <team@example.com>\r
        Bcc: Archive <archive@example.com>\r
        Message-ID: <fallback@example.com>\r
        In-Reply-To: <root@example.com>\r
        References: <root@example.com> <child@example.com>\r
        X-Campaign-ID: winter-2026\r
        \r
        """
        let fields = ["Date", "Subject", "From", "To", "Cc", "Bcc", "Message-ID", "In-Reply-To", "References"]

        let infos = try await executeFetch([
            fetchResponse(sequenceNumber: 1, headerFields: fields, headerBlock: headerBlock),
            "A001 OK FETCH completed\r\n"
        ])

        #expect(infos.count == 1)
        #expect(infos[0].subject == "What's New at A-Basin This Winter?")
        #expect(infos[0].from == "Arapahoe Basin <info@connect.arapahoebasin.com>")
        #expect(infos[0].to == ["Joel <joel@example.com>", "Michelle <michelle@example.com>"])
        #expect(infos[0].cc == ["Team <team@example.com>"])
        #expect(infos[0].bcc == ["Archive <archive@example.com>"])
        let expectedDate = Self.makeDate(
            DateComponents(year: 2026, month: 8, day: 5, hour: 18, minute: 13, second: 59)
        )
        #expect(infos[0].date == expectedDate)
        #expect(infos[0].messageId == MessageID("<fallback@example.com>"))
        #expect(infos[0].inReplyTo == MessageID("<root@example.com>"))
        #expect(infos[0].references == [MessageID("<root@example.com>")!, MessageID("<child@example.com>")!])
        #expect(infos[0].additionalFields?["x-campaign-id"] == "winter-2026")
    }

    @Test
    func testHeaderFieldsDoNotOverrideEnvelopeFields() async throws {
        let envelope = "(\"Wed, 05 Aug 2026 10:00:00 -0600\" \"Envelope subject\""
            + " ((\"Envelope Sender\" NIL \"envelope\" \"example.com\")) NIL NIL"
            + " ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<envelope@example.com>\")"
        let headerBlock = """
        Date: Wed, 05 Aug 2026 12:13:59 -0600\r
        Subject: Header subject\r
        From: Header Sender <header@example.com>\r
        To: Header Recipient <header-recipient@example.com>\r
        Message-ID: <header@example.com>\r
        In-Reply-To: <root@example.com>\r
        \r
        """
        let fields = ["Date", "Subject", "From", "To", "Message-ID", "In-Reply-To"]

        let infos = try await executeFetch([
            fetchResponse(
                sequenceNumber: 1,
                envelope: envelope,
                headerFields: fields,
                headerBlock: headerBlock
            ),
            "A001 OK FETCH completed\r\n"
        ])

        #expect(infos.count == 1)
        #expect(infos[0].subject == "Envelope subject")
        #expect(infos[0].from == "\"Envelope Sender\" <envelope@example.com>")
        #expect(infos[0].to == ["recipient@example.com"])
        let expectedDate = Self.makeDate(DateComponents(year: 2026, month: 8, day: 5, hour: 16))
        #expect(infos[0].date == expectedDate)
        #expect(infos[0].messageId == MessageID("<envelope@example.com>"))
        #expect(infos[0].inReplyTo == MessageID("<root@example.com>"))
    }

    @Test
    func testLegacyEightBitHeaderDoesNotDiscardSelectiveHeaderBlock() async throws {
        var headerBytes = Data("Subject: Legacy receipt\r\nFrom: Ren".utf8)
        headerBytes.append(0xE9)
        headerBytes.append(contentsOf: " <rene@example.com>\r\nMessage-ID: <legacy@example.com>\r\n\r\n".utf8)
        let fields = ["Subject", "From", "Message-ID"]

        let infos = try await executeFetch([
            fetchResponse(sequenceNumber: 1, headerFields: fields, headerBytes: headerBytes),
            Data("A001 OK FETCH completed\r\n".utf8)
        ])

        #expect(infos.count == 1)
        #expect(infos[0].subject == "Legacy receipt")
        #expect(infos[0].from == "René <rene@example.com>")
        #expect(infos[0].messageId == MessageID("<legacy@example.com>"))
    }

    private static func makeDate(_ components: DateComponents) -> Date? {
        var resolved = components
        resolved.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: resolved)
    }

    private func executeFetch(_ rawResponses: [String]) async throws -> [MessageInfo] {
        try await executeFetch(rawResponses.map { Data($0.utf8) })
    }

    private func executeFetch(_ rawResponses: [Data]) async throws -> [MessageInfo] {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let promise = channel.eventLoop.makePromise(of: [MessageInfo].self)
        let handler = FetchMessageInfoHandler(commandTag: "A001", promise: promise)
        try await channel.pipeline.addHandler(handler)

        let command = TaggedCommand(tag: "A001", command: .noop)
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(.tagged(command)))
        _ = try await channel.readOutbound(as: ByteBuffer.self)

        for rawResponse in rawResponses {
            var buffer = channel.allocator.buffer(capacity: rawResponse.count)
            buffer.writeBytes(rawResponse)
            try await channel.writeInbound(buffer)
        }
        return try await promise.futureResult.get()
    }

    private func fetchResponse(
        sequenceNumber: Int,
        envelope: String? = nil,
        headerFields: [String],
        headerBlock: String
    ) -> String {
        let envelopeAttribute = envelope.map { "ENVELOPE \($0) " } ?? ""
        let fieldsList = headerFields.joined(separator: " ")
        let count = headerBlock.utf8.count
        return "* \(sequenceNumber) FETCH (\(envelopeAttribute)BODY[HEADER.FIELDS (\(fieldsList))] {\(count)}\r\n"
            + "\(headerBlock))\r\n"
    }

    private func fetchResponse(
        sequenceNumber: Int,
        headerFields: [String],
        headerBytes: Data
    ) -> Data {
        let fieldsList = headerFields.joined(separator: " ")
        var response = Data(
            "* \(sequenceNumber) FETCH (BODY[HEADER.FIELDS (\(fieldsList))] {\(headerBytes.count)}\r\n".utf8
        )
        response.append(headerBytes)
        response.append(contentsOf: ")\r\n".utf8)
        return response
    }
}
