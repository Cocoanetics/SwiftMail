import Foundation
import Testing
@testable import SwiftMail
import NIOIMAPCore
import NIO

/// Tests for Array<MessagePart> init from BodyStructure — rfc822 recursion and embedded MessageInfo.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MessagePartBodyStructureTests {

    // MARK: - Helpers

    /// Minimal Fields with no parameters, no ID, no encoding.
    private func emptyFields() -> BodyStructure.Fields {
        BodyStructure.Fields(parameters: [:], id: nil, contentDescription: nil, encoding: nil, octetCount: 0)
    }

    /// Create a simple text/plain singlepart BodyStructure.
    private func textPlainBody() -> BodyStructure {
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 10)
        let part = BodyStructure.Singlepart(kind: .text(text), fields: emptyFields())
        return .singlepart(part)
    }

    /// Create a simple text/html singlepart BodyStructure.
    private func textHtmlBody() -> BodyStructure {
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "html", lineCount: 20)
        let part = BodyStructure.Singlepart(kind: .text(text), fields: emptyFields())
        return .singlepart(part)
    }

    /// Create a ByteBuffer from a string.
    private func buffer(_ string: String) -> ByteBuffer {
        ByteBuffer(string: string)
    }

    /// Create a minimal Envelope with subject and from address.
    private func envelope(subject: String? = nil, fromName: String? = nil, fromMailbox: String = "user", fromHost: String = "example.com", date: String? = nil) -> Envelope {
        let subjectBuf: ByteBuffer? = subject.map { buffer($0) }
        let fromAddr = EmailAddress(
            personName: fromName.map { buffer($0) },
            sourceRoot: nil,
            mailbox: buffer(fromMailbox),
            host: buffer(fromHost)
        )
        let dateVal: InternetMessageDate? = date.map { InternetMessageDate($0) }
        return Envelope(
            date: dateVal,
            subject: subjectBuf,
            from: [.singleAddress(fromAddr)],
            sender: [],
            reply: [],
            to: [],
            cc: [],
            bcc: [],
            inReplyTo: nil,
            messageID: nil
        )
    }

    /// Create a message/rfc822 singlepart wrapping a nested body.
    private func rfc822Singlepart(envelope env: Envelope, nestedBody: BodyStructure) -> BodyStructure {
        let message = BodyStructure.Singlepart.Message(
            message: .rfc822,
            envelope: env,
            body: nestedBody,
            lineCount: 100
        )
        let part = BodyStructure.Singlepart(kind: .message(message), fields: emptyFields())
        return .singlepart(part)
    }

    // MARK: - Tests

    @Test
    func rfc822WithMultipartNestedBodyProducesInnerParts() {
        // message/rfc822 wrapping multipart/alternative(text/plain, text/html)
        let nested = BodyStructure.multipart(
            BodyStructure.Multipart(parts: [textPlainBody(), textHtmlBody()], mediaSubtype: .alternative)
        )
        let env = envelope(subject: "Forwarded email")
        let structure = rfc822Singlepart(envelope: env, nestedBody: nested)

        let parts = Array<MessagePart>(structure)

        // Should produce 3 parts: the rfc822 part itself + 2 inner parts
        #expect(parts.count == 3)

        // First part: message/rfc822 at section 1
        #expect(parts[0].contentType == "message/rfc822")
        #expect(parts[0].section.description == "1")
        #expect(parts[0].embeddedMessageInfo != nil)
        #expect(parts[0].embeddedMessageInfo?.subject == "Forwarded email")

        // Inner text/plain at section 1.1
        #expect(parts[1].contentType == "text/plain")
        #expect(parts[1].section.description == "1.1")

        // Inner text/html at section 1.2
        #expect(parts[2].contentType == "text/html")
        #expect(parts[2].section.description == "1.2")
    }

    @Test
    func rfc822WithSinglepartNestedBodyProducesInnerPart() {
        // message/rfc822 wrapping just text/plain (no multipart)
        let env = envelope(subject: "Simple forward")
        let structure = rfc822Singlepart(envelope: env, nestedBody: textPlainBody())

        let parts = Array<MessagePart>(structure)

        // Should produce 2 parts: the rfc822 part + the inner text/plain
        #expect(parts.count == 2)

        // First part: message/rfc822 at section 1
        #expect(parts[0].contentType == "message/rfc822")
        #expect(parts[0].section.description == "1")

        // Inner text/plain at section 1.1 (RFC 3501: singlepart content within rfc822 is at N.1)
        #expect(parts[1].contentType == "text/plain")
        #expect(parts[1].section.description == "1.1")
    }

    @Test
    func embeddedMessageInfoPopulatedFromEnvelope() {
        let env = envelope(
            subject: "Test Subject",
            fromName: "John Doe",
            fromMailbox: "john",
            fromHost: "example.com",
            date: "Mon, 01 Jan 2024 12:00:00 +0000"
        )
        let structure = rfc822Singlepart(envelope: env, nestedBody: textPlainBody())

        let parts = Array<MessagePart>(structure)

        let info = parts[0].embeddedMessageInfo
        #expect(info != nil)
        #expect(info?.subject == "Test Subject")
        #expect(info?.from == "\"John Doe\" <john@example.com>")
        #expect(info?.date != nil)
    }

    @Test
    func rfc822FilenameFromEnvelopeSubject() {
        let env = envelope(subject: "Important: Meeting Notes")
        let structure = rfc822Singlepart(envelope: env, nestedBody: textPlainBody())

        let parts = Array<MessagePart>(structure)

        // Filename should be sanitized subject + .eml
        #expect(parts[0].filename == "Important- Meeting Notes.eml")
    }

    @Test
    func rfc822FilenameDefaultsToMessageEml() {
        // No subject
        let env = envelope()
        let structure = rfc822Singlepart(envelope: env, nestedBody: textPlainBody())

        let parts = Array<MessagePart>(structure)
        #expect(parts[0].filename == "message.eml")
    }

    @Test
    func rfc822SkipsCIDFallbackForFilename() {
        // message/rfc822 with a Content-ID — should NOT use CID as filename
        let message = BodyStructure.Singlepart.Message(
            message: .rfc822,
            envelope: envelope(subject: "With CID"),
            body: textPlainBody(),
            lineCount: 10
        )
        var fields = emptyFields()
        fields.id = "<cid-value@example.com>"
        let part = BodyStructure.Singlepart(kind: .message(message), fields: fields)
        let structure = BodyStructure.singlepart(part)

        let parts = Array<MessagePart>(structure)

        // Filename should come from subject, NOT from CID
        #expect(parts[0].filename == "With CID.eml")
    }

    @Test
    func nonMessagePartUsesCIDAsFilename() {
        // A basic image part with Content-ID but no filename — should use CID
        let mediaType = Media.MediaType(topLevel: "image", sub: "png")
        var fields = emptyFields()
        fields.id = "<image123@example.com>"
        let part = BodyStructure.Singlepart(kind: .basic(mediaType), fields: fields)
        let structure = BodyStructure.singlepart(part)

        let parts = Array<MessagePart>(structure)

        #expect(parts[0].filename == "image123@example.com")
    }

    @Test
    func rfc822InsideMultipartMixed() {
        // multipart/mixed(text/plain, message/rfc822(multipart/alternative(text/plain, text/html)))
        let innerNested = BodyStructure.multipart(
            BodyStructure.Multipart(parts: [textPlainBody(), textHtmlBody()], mediaSubtype: .alternative)
        )
        let rfc822 = rfc822Singlepart(envelope: envelope(subject: "Nested"), nestedBody: innerNested)
        let outerBody = textPlainBody()

        let structure = BodyStructure.multipart(
            BodyStructure.Multipart(parts: [outerBody, rfc822], mediaSubtype: .mixed)
        )

        let parts = Array<MessagePart>(structure)

        // Should have: text/plain(1), message/rfc822(2), text/plain(2.1), text/html(2.2)
        #expect(parts.count == 4)
        #expect(parts[0].contentType == "text/plain")
        #expect(parts[0].section.description == "1")
        #expect(parts[1].contentType == "message/rfc822")
        #expect(parts[1].section.description == "2")
        #expect(parts[2].contentType == "text/plain")
        #expect(parts[2].section.description == "2.1")
        #expect(parts[3].contentType == "text/html")
        #expect(parts[3].section.description == "2.2")
    }

    @Test
    func bodyContentReturnsFirstMatch() {
        // Message with two text/plain parts (e.g., from nested rfc822)
        let header = MessageInfo(sequenceNumber: SequenceNumber(1))
        let part1 = MessagePart(section: Section([1]), contentType: "text/plain", data: "First body".data(using: .utf8))
        let part2 = MessagePart(section: Section([2]), contentType: "text/plain", data: "Second body".data(using: .utf8))
        let message = Message(header: header, parts: [part1, part2])

        // textBody should return only the first match, not concatenation
        #expect(message.textBody == "First body")
    }

    @Test
    func embeddedMessageInfoEnvelopeDate() {
        // Test that envelope date is parsed correctly
        let env = envelope(date: "Tue, 15 Oct 2024 09:30:00 +0000")
        let structure = rfc822Singlepart(envelope: env, nestedBody: textPlainBody())
        let parts = Array<MessagePart>(structure)

        let info = parts[0].embeddedMessageInfo
        #expect(info?.date != nil)

        // Verify the parsed date components
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: info!.date!)
        #expect(components.year == 2024)
        #expect(components.month == 10)
        #expect(components.day == 15)
    }
}
