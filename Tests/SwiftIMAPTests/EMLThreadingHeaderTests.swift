// EMLThreadingHeaderTests.swift
// In-Reply-To and References are read into MessageInfo.

import Testing
import Foundation
@testable import SwiftMail

@Suite("EML threading headers", .serialized, .tags(.mime), .timeLimit(.minutes(1)))
struct EMLThreadingHeaderTests {
    private func parse(_ headers: String) throws -> MessageInfo {
        let eml = headers + "\r\nSubject: Re: Plan\r\nContent-Type: text/plain\r\n\r\nYes.\r\n"
        return try EMLParser.parse(Data(eml.utf8)).header
    }

    @Test("In-Reply-To and a folded References become MessageIDs, in order")
    func threadingHeaders() throws {
        let info = try parse("""
        From: b@example.com\r
        Message-ID: <reply@example.com>\r
        In-Reply-To: <parent@example.com>\r
        References: <root@example.com>\r
         <parent@example.com>
        """)
        #expect(info.messageId?.description == "<reply@example.com>")
        #expect(info.inReplyTo?.description == "<parent@example.com>")
        #expect(info.references?.map(\.description) == ["<root@example.com>", "<parent@example.com>"])
        // Still available as raw fields, as before.
        #expect(info.additionalFields?["in-reply-to"] == "<parent@example.com>")
    }

    @Test("Comments and phrases between ids are skipped")
    func commentsBetweenIDs() throws {
        let info = try parse("""
        From: b@example.com\r
        In-Reply-To: <parent@example.com> (Alice's message of Monday)\r
        References: <root@example.com> (thread start) <parent@example.com>
        """)
        #expect(info.inReplyTo?.description == "<parent@example.com>")
        #expect(info.references?.map(\.description) == ["<root@example.com>", "<parent@example.com>"])
    }

    @Test("An id inside a comment is not a threading id", arguments: [
        ("(previously <unrelated@example.com>) <parent@example.com>", ["<parent@example.com>"]),
        ("<root@example.com> (was (nested <x@example.com>)) <parent@example.com>",
         ["<root@example.com>", "<parent@example.com>"]),
        (#"(an escaped \) then <x@example.com>) <parent@example.com>"#, ["<parent@example.com>"]),
        (#"(an escaped \( <x@example.com>) <parent@example.com>"#, ["<parent@example.com>"])
    ])
    func idsInsideComments(field: String, expected: [String]) throws {
        let info = try parse("From: b@example.com\r\nIn-Reply-To: \(field)\r\nReferences: \(field)")
        #expect(info.inReplyTo?.description == expected.first)
        #expect(info.references?.map(\.description) == expected)
    }

    @Test("An id inside a quoted phrase is not a threading id")
    func idsInsideQuotedPhrase() throws {
        let field = #""Alice <alice@example.com> \" wrote" <parent@example.com>"#
        #expect(EMLParser.messageIDs(in: field).map(\.description) == ["<parent@example.com>"])
        // A parenthesis inside quotes doesn't open a comment.
        #expect(EMLParser.messageIDs(in: #""(not a comment" <parent@example.com>"#).map(\.description)
                == ["<parent@example.com>"])
    }

    @Test("A message without them has neither")
    func absent() throws {
        let info = try parse("From: b@example.com")
        #expect(info.inReplyTo == nil)
        #expect(info.references == nil)
    }
}
