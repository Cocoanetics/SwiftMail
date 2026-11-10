import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
import NIOIMAPCore
import Testing
@testable import SwiftMail

/// Outlook writes Windows paths into attachment names without escaping them,
/// and Dovecot's BODYSTRUCTURE resolves each `\x` to `x`. The part's MIME
/// header still holds the backslashes; `fetchStructure` reads them back.
@Suite("Filenames from MIME headers")
struct MIMEHeaderFilenameTests {
    /// The header of part 2 as Outlook sent it.
    static let outlookHeader = Data(#"""
    Content-Type: application/octet-stream;\#r
    \#tname="zpo-berufung\reference\akt.md"\#r
    Content-Transfer-Encoding: quoted-printable\#r
    Content-Disposition: attachment;\#r
    \#tfilename="zpo-berufung\reference\akt.md"\#r
    \#r

    """#.utf8)

    static let parts = [
        MessagePart(section: Section([1]), contentType: "text/plain"),
        MessagePart(section: Section([2]), contentType: "application/octet-stream",
                    disposition: "attachment", filename: "zpo-berufungreferenceakt.md"),
        MessagePart(section: Section([3]), contentType: "image/png", filename: "logo.png")
    ]

    @Test("Named parts are the candidates; a single-part message has none")
    func candidates() {
        #expect(Self.parts.sectionsForFilenameCheck == [Section([2]), Section([3])])
        #expect([MessagePart(section: Section([1]), contentType: "application/pdf", filename: "a.pdf")]
            .sectionsForFilenameCheck.isEmpty)
    }

    @Test("The header's backslashes are put back into the BODYSTRUCTURE name")
    func restoresBackslashes() {
        let restored = Self.parts.restoringFilenames(fromMIMEHeaders: [Section([2]): Self.outlookHeader])

        #expect(restored[1].filename == #"zpo-berufung\reference\akt.md"#)
        #expect(restored[1].disposition == "attachment")
        #expect(restored[0].filename == nil)
        #expect(restored[2].filename == "logo.png")
    }

    @Test("A backslash sharing a character with a neighbouring scalar is put back",
          arguments: ["a\\\u{0301}b.md", "a\\\u{FE0F}b.md", "a\\\u{1F3FB}b.md", "a\\\u{200D}b.md",
                      "a\u{0600}\\b.md"])
    func restoresABackslashNextToAJoiningScalar(name: String) {
        // The header names the file with a backslash that shares a character with
        // a combining mark, variation selector, emoji modifier or joiner after it,
        // or with a prepended scalar (U+0600) before it; the BODYSTRUCTURE name
        // lost the backslash.
        let header = Data("Content-Type: application/octet-stream; name=\"\(name)\"\r\n\r\n".utf8)
        let withoutBackslash = String(String.UnicodeScalarView(name.unicodeScalars.filter { $0 != "\\" }))
        let part = MessagePart(section: Section([2]), contentType: "application/octet-stream",
                               disposition: "attachment", filename: withoutBackslash)

        let restored = [part].restoringFilenames(fromMIMEHeaders: [Section([2]): header])

        #expect(restored.count == 1)
        guard restored.count == 1 else { return }
        #expect(restored[0].filename.map { Array($0.unicodeScalars) } == Array(name.unicodeScalars))
    }

    @Test("A header naming anything but the same name with backslashes is ignored",
          arguments: zip(
              // The header's name: another name, the same letters in another case, the
              // same text with a backslash spelled with other scalars (NFD and NFC), and
              // the name with backslashes and extra text, or with part of it missing.
              ["other.png", "a\\Report.md", "cafe\u{0301}\\\u{200D}notes.md", "caf\u{E9}\\notes.md",
               "a\\b.md.txt", "a\\b"],
              // The BODYSTRUCTURE name.
              ["logo.png", "areport.md", "caf\u{E9}\u{200D}notes.md", "cafe\u{0301}notes.md",
               "ab.md", "ab.md"]))
    func otherNamesAreIgnored(headerName: String, current: String) {
        let header = Data("Content-Type: application/octet-stream; name=\"\(headerName)\"\r\n\r\n".utf8)
        let part = MessagePart(section: Section([2]), contentType: "application/octet-stream",
                               disposition: "attachment", filename: current)

        let restored = [part].restoringFilenames(fromMIMEHeaders: [Section([2]): header])

        #expect(restored.count == 1)
        guard restored.count == 1 else { return }
        #expect(restored[0].filename.map { Array($0.unicodeScalars) } == Array(current.unicodeScalars))
    }

    @Test("The handler keeps each header up to its cap and none of the streamed bytes in its history")
    func handlerBoundsWhatItKeeps() throws {
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: [Section: Data].self)
        let handler = FetchMIMEHeadersHandler(commandTag: "A1", promise: promise, sections: [Section([2])])
        let specifier = FetchMIMEHeadersCommand<SwiftMail.UID>.specifier(for: Section([2]))
        let oversized = FetchMIMEHeadersHandler.maximumHeaderBytes + 1000
        let chunk = ByteBuffer(repeating: UInt8(ascii: "x"), count: 4096)

        _ = handler.processResponse(.fetch(.start(1)))
        _ = handler.processResponse(.fetch(.streamingBegin(kind: .body(section: specifier, offset: nil),
                                                           byteCount: oversized)))
        for _ in 0..<(oversized / chunk.readableBytes + 1) {
            _ = handler.processResponse(.fetch(.streamingBytes(chunk)))
        }
        _ = handler.processResponse(.fetch(.streamingEnd))
        _ = handler.processResponse(.fetch(.finish))
        #expect(handler.untaggedResponses.isEmpty)

        _ = handler.processResponse(.tagged(TaggedResponse(tag: "A1", state: .ok(ResponseText(text: "done")))))
        let headers = try promise.futureResult.wait()
        #expect(headers[Section([2])]?.count == FetchMIMEHeadersHandler.maximumHeaderBytes)
    }

    #if os(macOS)
        /// BODYSTRUCTURE as Dovecot sends it for the Outlook message: the
        /// attachment's name and filename have lost their backslashes.
        static let dovecotBodystructure = """
        (("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 5 1 NIL NIL NIL NIL)\
        ("APPLICATION" "OCTET-STREAM" ("NAME" "zpo-berufungreferenceakt.md") NIL NIL "QUOTED-PRINTABLE" 120 NIL \
        ("ATTACHMENT" ("FILENAME" "zpo-berufungreferenceakt.md")) NIL NIL) \
        "MIXED" ("BOUNDARY" "b") NIL NIL NIL)
        """

        @Test("fetchStructure reads the name back from the part's MIME header")
        func fetchStructureRestoresFilename() async throws {
            let filenames = try await fetchedFilenames(rejectsMIMEHeaderFetch: false)
            #expect(filenames == [nil, #"zpo-berufung\reference\akt.md"#])
        }

        @Test("fetchStructure keeps the BODYSTRUCTURE name when the MIME headers are refused")
        func fetchStructureFallsBack() async throws {
            let filenames = try await fetchedFilenames(rejectsMIMEHeaderFetch: true)
            #expect(filenames == [nil, "zpo-berufungreferenceakt.md"])
        }

        private func fetchedFilenames(rejectsMIMEHeaderFetch: Bool) async throws -> [String?] {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let maildir = tempRoot.appendingPathComponent("Maildir")
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("cur"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: maildir.appendingPathComponent("new"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let eml = "From: a@example.com\r\nTo: b@example.com\r\nSubject: Paths\r\n"
                + "Content-Type: text/plain\r\n\r\nHello\r\n"
            try Data(eml.utf8).write(to: maildir.appendingPathComponent("cur/1.eml"))

            let testServer = try IMAPTestServer(
                bodystructureOverride: Self.dovecotBodystructure,
                mimeHeaders: ["2": try #require(String(bytes: Self.outlookHeader, encoding: .utf8))],
                rejectsMIMEHeaderFetch: rejectsMIMEHeaderFetch,
                maildirURL: maildir
            )
            try testServer.start()

            var filenames: [String?] = []
            try await testServer.run {
                let server = IMAPServer(host: "127.0.0.1", port: testServer.port, useTLS: false)
                try await server.connect()
                try await server.login(username: "testuser", password: "testpass")
                _ = try await server.selectMailbox("INBOX")

                filenames = try await server.fetchStructure(SwiftMail.UID(1)).map(\.filename)

                try await server.disconnect()
            }
            #expect(testServer.commandLog.contains { $0.uppercased().contains("BODY.PEEK[2.MIME]") })
            return filenames
        }
    #endif
}

/// The lenient reading is for filenames only; other parameters stay by the RFC.
@Suite("Backslashes outside filenames")
struct StrictParameterBackslashTests {
    @Test("A boundary's quoted-pair is resolved, as its delimiter lines carry it")
    func boundaryStaysStrict() {
        #expect(EMLParser.extractBoundary(from: #"multipart/mixed; boundary="foo\bar""#) == "foobar")
    }

    @Test("A multipart whose boundary is written with a quoted-pair still splits")
    func multipartWithEscapedBoundarySplits() throws {
        let eml = "From: a@example.com\r\nSubject: Boundary\r\n"
            + "Content-Type: multipart/mixed; boundary=\"foo\\bar\"\r\n\r\n"
            + "--foobar\r\nContent-Type: text/plain\r\n\r\nOne\r\n"
            + "--foobar\r\nContent-Type: text/plain\r\n\r\nTwo\r\n--foobar--\r\n"

        let message = try Message(emlData: Data(eml.utf8))
        #expect(message.parts.count == 2)
    }
}
