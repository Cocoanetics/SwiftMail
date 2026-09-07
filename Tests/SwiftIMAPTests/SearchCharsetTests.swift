import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

/// RFC 3501 §6.4.4 assumes US-ASCII when `SEARCH` carries no `CHARSET`, so a search string
/// with non-ASCII bytes must be sent as `CHARSET UTF-8`. Gmail answers
/// `BAD Could not parse command` when it is missing.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SearchCharsetTests {
    @Test
    func extendedSearchAddsUTF8CharsetForNonASCIISubject() async throws {
        let command = ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.subject("Morning brief — Saturday")],
            useEsearch: true
        )
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "C001"))

        #expect(wire.hasPrefix("C001 UID SEARCH RETURN (COUNT MIN MAX ALL) CHARSET UTF-8 "))
        #expect(wire.contains("SUBJECT {26}\r\nMorning brief — Saturday"))
    }

    @Test
    func extendedSearchOmitsCharsetForASCIICriteria() async throws {
        let command = ExtendedSearchCommand<SwiftMail.UID>(
            criteria: [.subject("Morning brief"), .from("news@example.com")],
            useEsearch: true
        )
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "C002"))

        #expect(!wire.contains("CHARSET"))
        #expect(wire.contains("SUBJECT \"Morning brief\""))
    }

    @Test
    func plainSearchAddsUTF8CharsetForNestedNonASCIIText() async throws {
        let command = SearchCommand<SwiftMail.UID>(
            criteria: [.or(.from("news@example.com"), .text("café"))]
        )
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "C003"))

        #expect(wire.hasPrefix("C003 UID SEARCH CHARSET UTF-8 "))
        #expect(wire.contains("OR FROM \"news@example.com\" TEXT {5}\r\ncafé"))
    }

    @Test
    func plainSearchOmitsCharsetForASCIICriteria() async throws {
        let command = SearchCommand<SwiftMail.UID>(criteria: [.text("invoice")])
        let wire = try await Self.wireFormat(of: command.toTaggedCommand(tag: "C004"))

        #expect(wire.hasPrefix("C004 UID SEARCH "))
        #expect(!wire.contains("CHARSET"))
        #expect(wire.contains("TEXT \"invoice\""))
    }

    @Test
    func charsetDetectionCoversStringCarryingCriteria() {
        #expect(SearchCriteria.header("Subject", "naïve").requiresUTF8Charset)
        #expect(SearchCriteria.not(.body("Grüße")).requiresUTF8Charset)
        #expect(SearchCriteria.and([.seen, .to("ærlig@example.com")]).requiresUTF8Charset)
        #expect(!SearchCriteria.and([.seen, .to("plain@example.com")]).requiresUTF8Charset)
        #expect(!SearchCriteria.keyword("$Important").requiresUTF8Charset)
        #expect(SearchCriteria.searchCharset(for: [.subject("plain")]) == nil)
        #expect(SearchCriteria.searchCharset(for: [.seen, .subject("Ünïcode")]) == "UTF-8")
    }

    /// Renders the command bytes. A search string that NIO IMAP must send as a synchronizing
    /// literal stops the encoder at `{n}\r\n` until the server continues, so this answers each
    /// literal announcement with `+` the way a server would and returns the complete wire format.
    private static func wireFormat(of tagged: TaggedCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        let wrapped = IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged))
        let write = Task { try await channel.writeAndFlush(wrapped) }
        var wire = ""
        for _ in 0..<4 {
            var chunk = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
            wire += chunk.readString(length: chunk.readableBytes) ?? ""
            guard wire.hasSuffix("}\r\n") else { break }
            try await channel.writeInbound(ByteBuffer(string: "+ Ready\r\n"))
        }
        try await write.value
        return wire
    }
}
