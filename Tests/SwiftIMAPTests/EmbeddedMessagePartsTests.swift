// EmbeddedMessagePartsTests.swift
// Tests for pairing embedded messages with the message/rfc822 part that carries them

import Foundation
import Testing
@testable import SwiftMail

@Suite("Embedded Message Parts Tests", .tags(.mime))
struct EmbeddedMessagePartsTests {

    private static func part(
        _ section: String,
        _ contentType: String,
        filename: String? = nil,
        text: String? = nil,
        subject: String? = nil
    ) -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: contentType,
            filename: filename,
            data: text.map { Data($0.utf8) },
            embeddedMessageInfo: subject.map { MessageInfo(sequenceNumber: SequenceNumber(1), subject: $0) }
        )
    }

    /// A flat layout modelled on an IMAP BODYSTRUCTURE: a body, a forwarded
    /// message that itself forwards one, and a second forwarded message.
    private static func forwardingMessage() -> Message {
        let parts = [
            part("1", "text/plain; charset=utf-8", text: "Outer body"),
            part("2", "message/rfc822", filename: "first.eml", subject: "First"),
            part("2.1", "text/html; charset=utf-8", text: "<p>First body</p>"),
            part("2.2", "message/rfc822", filename: "inner.eml", subject: "Inner"),
            part("2.2.1", "text/plain; charset=utf-8", text: "Inner body"),
            part("3", "message/rfc822", subject: "Second"),
            part("3.1", "text/plain; charset=utf-8", text: "Second body")
        ]
        return Message(header: MessageInfo(sequenceNumber: SequenceNumber(1), subject: "Outer"), parts: parts)
    }

    @Test("Each embedded message comes with the part that carries it")
    func embeddedMessagesComeWithTheirParts() {
        let embedded = Self.forwardingMessage().embeddedMessagesWithParts

        #expect(embedded.map(\.part.section.description) == ["2", "3"])
        #expect(embedded.map(\.part.filename) == ["first.eml", nil])
        #expect(embedded.map(\.message.subject) == ["First", "Second"])
        #expect(embedded.allSatisfy { $0.part.contentType == "message/rfc822" })
    }

    @Test("The pairs list the same messages as embeddedMessages, in the same order")
    func pairsMatchEmbeddedMessages() {
        let message = Self.forwardingMessage()

        #expect(message.embeddedMessagesWithParts.map(\.message.subject) == message.embeddedMessages.map(\.subject))
        #expect(
            message.embeddedMessagesWithParts.map { $0.message.parts.map(\.section.description) }
                == message.embeddedMessages.map { $0.parts.map(\.section.description) }
        )
    }

    @Test("A message forwarded inside a forwarded one pairs with its part, numbered within its parent")
    func nestedEmbeddedMessagePairsWithinItsParent() throws {
        let first = try #require(Self.forwardingMessage().embeddedMessagesWithParts.first)

        #expect(first.message.textBody == nil)
        #expect(first.message.htmlBody == "<p>First body</p>")

        let inner = first.message.embeddedMessagesWithParts
        #expect(inner.count == 1)
        guard inner.count == 1 else { return }
        #expect(inner[0].part.section.description == "2")
        // Its fetch section is the enclosing part's followed by its own.
        #expect(Section(first.part.section.components + inner[0].part.section.components).description == "2.2")
        #expect(inner[0].part.filename == "inner.eml")
        #expect(inner[0].message.subject == "Inner")
        #expect(inner[0].message.textBody == "Inner body")
        #expect(inner[0].message.embeddedMessagesWithParts.isEmpty)
    }

    @Test("A message with nothing embedded has no pairs")
    func noEmbeddedMessages() {
        let message = Message(
            header: MessageInfo(sequenceNumber: SequenceNumber(1)),
            parts: [Self.part("1", "text/plain", text: "Body")]
        )
        #expect(message.embeddedMessagesWithParts.isEmpty)
    }
}
