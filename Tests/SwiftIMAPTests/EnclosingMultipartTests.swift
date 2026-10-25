// EnclosingMultipartTests.swift
// Tests for the multipart bodies each message part records as enclosing it

import Foundation
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

@Suite("Enclosing multiparts", .tags(.mime), .timeLimit(.minutes(1)))
struct EnclosingMultipartTests {

    // MARK: - Helpers

    private static func fields() -> BodyStructure.Fields {
        BodyStructure.Fields(parameters: [:], id: nil, contentDescription: nil, encoding: nil, octetCount: 0)
    }

    private static func text(_ subtype: String) -> BodyStructure {
        .singlepart(BodyStructure.Singlepart(
            kind: .text(BodyStructure.Singlepart.Text(mediaSubtype: Media.Subtype(subtype), lineCount: 1)),
            fields: fields()))
    }

    private static func image() -> BodyStructure {
        .singlepart(BodyStructure.Singlepart(
            kind: .basic(Media.MediaType(topLevel: "image", sub: "png")), fields: fields()))
    }

    private static func multipart(_ subtype: Media.Subtype, _ parts: [BodyStructure]) -> BodyStructure {
        .multipart(BodyStructure.Multipart(parts: parts, mediaSubtype: subtype))
    }

    private static func message(_ body: BodyStructure) -> BodyStructure {
        let envelope = Envelope(
            date: nil, subject: ByteBuffer(string: "Forwarded"), from: [], sender: [], reply: [],
            to: [], cc: [], bcc: [], inReplyTo: nil, messageID: nil)
        return .singlepart(BodyStructure.Singlepart(
            kind: .message(BodyStructure.Singlepart.Message(
                message: .rfc822, envelope: envelope, body: body, lineCount: 1)),
            fields: fields()))
    }

    /// mixed(alternative(text/plain, text/html), image/png), the shape a mail app
    /// writes for a body with an attachment.
    private static let mixedWithAlternative = multipart(.mixed, [
        multipart(.alternative, [text("plain"), text("html")]),
        image()
    ])

    private static let mixed = EnclosingMultipart(path: [], subtype: "mixed")
    private static let alternative = EnclosingMultipart(path: [1], subtype: "alternative")

    /// The same shape as `mixedWithAlternative`, as an `.eml`.
    private static let mixedWithAlternativeEML = """
        From: sender@example.com\r
        To: recipient@example.com\r
        Subject: Shapes\r
        MIME-Version: 1.0\r
        Content-Type: Multipart/Mixed; boundary="outer"\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Plain\r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML</p>\r
        --inner--\r
        --outer\r
        Content-Type: image/png\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw==\r
        --outer--\r
        """

    // MARK: - BODYSTRUCTURE

    @Test("Each part built from a BODYSTRUCTURE records the multiparts around it, outermost first")
    func bodyStructurePartsRecordTheirMultiparts() {
        let parts = [MessagePart](Self.mixedWithAlternative)

        #expect(parts.map(\.section.description) == ["1.1", "1.2", "2"])
        #expect(parts.map(\.enclosingMultiparts) == [
            [Self.mixed, Self.alternative],
            [Self.mixed, Self.alternative],
            [Self.mixed]
        ])
    }

    @Test("The branch of a multipart tells its alternatives apart and the pieces of a mixed body")
    func branchNumbersTheChildHoldingThePart() {
        let parts = [MessagePart](Self.mixedWithAlternative)
        guard parts.count == 3 else { return }

        #expect(parts.map { $0.branch(of: Self.alternative) } == [1, 2, nil])
        #expect(parts.map { $0.branch(of: Self.mixed) } == [1, 1, 2])
        #expect(parts[0].branch(of: EnclosingMultipart(path: [1], subtype: "related")) == nil,
                "a multipart that does not enclose the part has no branch")
    }

    @Test("A single-part body has no enclosing multipart")
    func singlePartHasNone() {
        let parts = [MessagePart](Self.text("plain"))

        #expect(parts.map(\.enclosingMultiparts) == [[]])
    }

    @Test("An attached message's multipart is numbered under the message's section")
    func attachedMessageMultipartSitsAtItsSection() {
        let structure = Self.multipart(.mixed, [
            Self.text("plain"),
            Self.message(Self.multipart(.alternative, [Self.text("plain"), Self.text("html")]))
        ])
        let parts = [MessagePart](structure)
        let inner = EnclosingMultipart(path: [2], subtype: "alternative")

        #expect(parts.map(\.section.description) == ["1", "2", "2.1", "2.2"])
        #expect(parts.map(\.enclosingMultiparts) == [
            [Self.mixed], [Self.mixed], [Self.mixed, inner], [Self.mixed, inner]
        ])
        #expect(parts.map { $0.branch(of: inner) } == [nil, nil, 1, 2])

        let embedded = Message(header: MessageInfo(sequenceNumber: SequenceNumber(1)), parts: parts)
            .embeddedMessagesWithParts
        guard embedded.count == 1 else { return }
        #expect(embedded[0].message.parts.map(\.enclosingMultiparts) == [
            [EnclosingMultipart(path: [], subtype: "alternative")],
            [EnclosingMultipart(path: [], subtype: "alternative")]
        ], "inside the attached message, its multipart is the top-level body")
    }

    @Test("An extracted message keeps the paths of its nested multiparts, relative to itself",
          arguments: [false, true])
    func extractedMessageRebasesNestedMultiparts(deep: Bool) throws {
        let carried = Self.message(Self.multipart(.mixed, [
            Self.multipart(.alternative, [Self.text("plain"), Self.text("html")]),
            Self.text("plain")
        ]))
        let structure = Self.multipart(.mixed, deep
            ? [Self.multipart(.related, [Self.text("plain"), carried]), Self.text("plain")]
            : [Self.text("plain"), carried])
        let message = Message(header: MessageInfo(sequenceNumber: SequenceNumber(1)), parts: [MessagePart](structure))
        let nested = try #require(message.embeddedMessagesWithParts.first).message
        let alternative = EnclosingMultipart(path: [1], subtype: "alternative")

        #expect(nested.parts.map(\.section.description) == ["1.1", "1.2", "2"])
        #expect(nested.parts.map(\.enclosingMultiparts) == [
            [Self.mixed, alternative], [Self.mixed, alternative], [Self.mixed]
        ])
        #expect(nested.parts.map { $0.branch(of: alternative) } == [1, 2, nil])
    }

    // MARK: - EML

    @Test("Parts parsed from an .eml record the same multiparts as from its BODYSTRUCTURE")
    func emlPartsMatchBodyStructure() throws {
        let message = try Message(emlData: Data(Self.mixedWithAlternativeEML.utf8))

        #expect(message.parts.map(\.section.description) == ["1.1", "1.2", "2"])
        #expect(message.parts.map(\.enclosingMultiparts)
            == [MessagePart](Self.mixedWithAlternative).map(\.enclosingMultiparts))
    }

    @Test("A single-part .eml has no enclosing multipart")
    func singlePartEMLHasNone() throws {
        let message = try Message(emlData: Data(
            "From: sender@example.com\r\nSubject: One\r\nContent-Type: text/plain\r\n\r\nBody\r\n".utf8))

        #expect(message.parts.map(\.enclosingMultiparts) == [[]])
    }

    @Test("A comment in an .eml Content-Type is not part of the multipart subtype", arguments: [
        "multipart/Alternative (representation); boundary=b",
        "multipart/Alternative (a; b); boundary=b",
        "multipart/(a; b)Alternative; boundary=b",
        "multipart/Alternative (outer (inner) tail); boundary=b",
        "multipart/Alternative (a \\) ; b); boundary=b"
    ])
    func emlSubtypeIgnoresComments(_ contentType: String) throws {
        let message = try Message(emlData: Data((
            "From: sender@example.com\r\nSubject: Two\r\nContent-Type: \(contentType)\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nfirst\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nsecond\r\n--b--\r\n").utf8))
        let alternative = EnclosingMultipart(path: [], subtype: "alternative")

        #expect(message.parts.map(\.section.description) == ["1", "2"])
        #expect(message.parts.map(\.enclosingMultiparts) == [[alternative], [alternative]])
    }

    @Test("An .eml multipart with an empty subtype records it empty", arguments: [
        "multipart/; boundary=b",
        "multipart/(comment); boundary=b",
        "multipart/ ; boundary=b"
    ])
    func emlEmptySubtypeStaysEmpty(_ contentType: String) throws {
        let message = try Message(emlData: Data((
            "From: sender@example.com\r\nSubject: Empty\r\nContent-Type: \(contentType)\r\n\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nfirst\r\n"
            + "--b\r\nContent-Type: text/plain\r\n\r\nsecond\r\n--b--\r\n").utf8))
        let unnamed = EnclosingMultipart(path: [], subtype: "")

        #expect(message.parts.map(\.section.description) == ["1", "2"])
        #expect(message.parts.map(\.enclosingMultiparts) == [[unnamed], [unnamed]])
    }

    @Test("A nested multipart the .eml parser keeps opaque still records its enclosing multipart",
          arguments: ["multipart/alternative", "multipart/alternative; boundary=missing"])
    func opaqueEMLMultipartKeepsItsEnclosingMultipart(_ contentType: String) throws {
        let message = try Message(emlData: Data((
            "From: sender@example.com\r\nSubject: Opaque\r\nContent-Type: multipart/mixed; boundary=b\r\n\r\n"
            + "--b\r\nContent-Type: \(contentType)\r\n\r\nopaque bytes\r\n--b--\r\n").utf8))

        #expect(message.parts.map(\.section.description) == ["1"])
        #expect(message.parts.map(\.data) == [Data("opaque bytes".utf8)])
        #expect(message.parts.map(\.enclosingMultiparts) == [[Self.mixed]])
    }

    // MARK: - Copies and coding

    @Test("A part whose filename is restored keeps its multiparts")
    func restoredFilenameKeepsMultiparts() {
        let header = Data(#"Content-Type: image/png; name="a\b.png"\#r\#n\#r\#n"#.utf8)
        let part = MessagePart(
            section: Section([2]), contentType: "image/png", filename: "ab.png",
            enclosingMultiparts: [Self.mixed])
        let restored = [part].restoringFilenames(fromMIMEHeaders: [Section([2]): header])
        guard restored.count == 1 else { return }

        #expect(restored[0].filename == #"a\b.png"#)
        #expect(restored[0].enclosingMultiparts == [Self.mixed])
    }

    @Test("Multiparts survive encoding, and a part encoded without them decodes with none")
    func codingKeepsMultiparts() throws {
        let part = [MessagePart](Self.mixedWithAlternative)[0]
        let decoded = try JSONDecoder().decode(MessagePart.self, from: JSONEncoder().encode(part))
        #expect(decoded.enclosingMultiparts == [Self.mixed, Self.alternative])

        var older = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(part)) as? [String: Any])
        #expect(older.removeValue(forKey: "enclosingMultiparts") != nil)
        let olderData = try JSONSerialization.data(withJSONObject: older)
        #expect(try JSONDecoder().decode(MessagePart.self, from: olderData).enclosingMultiparts == [])
    }

    @Test("Both initializers keep the multiparts they are given")
    func initializersKeepMultiparts() {
        let enclosing = EnclosingMultipart(path: [1], subtype: "alternative")
        let parts = [
            MessagePart(section: Section([1, 2]), contentType: "text/plain", enclosingMultiparts: [enclosing]),
            MessagePart(sectionString: "1.2", contentType: "text/plain", enclosingMultiparts: [enclosing])
        ]

        #expect(parts.map(\.enclosingMultiparts) == [[enclosing], [enclosing]])
        #expect(parts.map { $0.branch(of: enclosing) } == [2, 2])
    }

    @Test("A multipart subtype is stored lowercased")
    func subtypeIsLowercased() {
        #expect(EnclosingMultipart(path: [], subtype: "Alternative").subtype == "alternative")
    }
}
