import Foundation
import Testing
@testable import SwiftMail

/// `sendDraft` sends the stored draft with every Bcc field removed. A header
/// line it cannot classify is refused rather than guessed at, so no blind
/// recipient can reach the delivered copy behind one.
@Suite("Bcc field removal")
struct BccFieldRemovalTests {
    private static func strip(_ text: String) throws -> String {
        String(bytes: try IMAPServer.removingBccFields(from: Data(text.utf8)), encoding: .utf8) ?? ""
    }

    @Test("removes a Bcc field and its folded continuation lines, any case")
    func removesFoldedBcc() throws {
        let raw = "From: me@example.com\r\nBCC: one@example.com,\r\n two@example.com,\r\n\tthree@example.com\r\n"
            + "To: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == "From: me@example.com\r\nTo: you@example.com\r\nSubject: Hi\r\n\r\nBody\r\n")
    }

    @Test("removes every Bcc field, whatever whitespace comes before the colon",
          arguments: ["", " ", "\t", "  ", " \t "])
    func removesEveryBcc(whitespace: String) throws {
        let raw = "Bcc: a@example.com\r\nTo: you@example.com\r\nbcc\(whitespace): b@example.com\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == "To: you@example.com\r\n\r\nBody\r\n")
    }

    @Test("keeps the body, even a body line that looks like a Bcc field")
    func keepsBody() throws {
        let raw = "To: you@example.com\r\n\r\nBcc: not-a-header@example.com\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    @Test("keeps fields whose name only starts or ends with Bcc")
    func keepsSimilarNames() throws {
        let raw = "X-Bcc: a@example.com\r\nBcc-Note: b\r\nResent-To: c@example.com\r\n\r\nBody\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    /// Resent-Bcc means what Bcc means (RFC 5322 section 3.6.6), and sendDraft
    /// does not send resent messages, so a draft carrying one is not sent.
    @Test("refuses a header with a Resent-Bcc field", arguments: ["Resent-Bcc", "resent-BCC", "Resent-Bcc \t"])
    func refusesResentBcc(name: String) {
        let raw = "To: you@example.com\r\n\(name): hidden@example.com\r\n\r\nBody\r\n"
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    @Test("keeps a Resent-Bcc line in the body")
    func keepsResentBccInBody() throws {
        let raw = "To: you@example.com\r\n\r\nResent-Bcc: not-a-header@example.com\r\n"
        #expect(try Self.strip(raw) == raw)
    }

    @Test("keeps folded visible fields byte for byte, and a whitespace-only continuation is not the blank line")
    func keepsFoldedVisibleFields() throws {
        let raw = "To: a@example.com,\r\n\tb@example.com\r\nX-Note: n\r\n \r\nBcc: hidden@example.com,\r\n \r\n"
            + " second@example.com\r\nCc: c@example.com\r\n\r\nBody\r\n"
        let stripped = try Self.strip(raw)
        #expect(stripped
            == "To: a@example.com,\r\n\tb@example.com\r\nX-Note: n\r\n \r\nCc: c@example.com\r\n\r\nBody\r\n")
        #expect(!stripped.contains("hidden@example.com"))
        #expect(!stripped.contains("second@example.com"))
    }

    @Test("keeps a line with no colon, and a header section with no blank line after it")
    func keepsMalformedLines() throws {
        #expect(try Self.strip("To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
            == "To: you@example.com\r\nbcc\r\nSubject: Hi\r\n\r\nBody")
        #expect(try Self.strip("To: you@example.com\r\nBcc: a@example.com") == "To: you@example.com\r\n")
    }

    /// Readers disagree on where a line with a lone carriage return ends, so a
    /// Bcc field could hide behind one. Such a header is refused, not guessed at.
    @Test("refuses a header with a carriage return that no line feed follows", arguments: [
        "To: you@example.com\r\n\rX-Note: odd\r\nBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\rBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\r\nBcc: a@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\nBcc: a@example.com\r"
    ])
    func refusesBareCRInHeader(raw: String) {
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    /// A line the stripper cannot tell is or is not a Bcc field is refused, not
    /// sent: a field name folded before its colon unfolds to "Bcc :" (RFC 5322
    /// sections 2.2.3 and 4.5), and readers disagree on a header that starts
    /// with a continuation or a name holding a control byte.
    @Test("refuses a header line it cannot tell is not a Bcc field", arguments: [
        "To: you@example.com\r\nBcc\r\n : hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\nbcc\r\n\t: hidden@example.com\r\n\r\nBody\r\n",
        " Bcc: hidden@example.com\r\nTo: you@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\nBcc\u{0B}: hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\nBcc\u{0C}: hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\n\u{0B}Bcc: hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\n: hidden@example.com\r\n\r\nBody\r\n"
    ])
    func refusesUnclassifiableLines(raw: String) {
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    @Test("keeps a lone carriage return in the body")
    func keepsBareCRInBody() throws {
        #expect(try Self.strip("To: you@example.com\r\nBcc: a@example.com\r\n\r\nBody\rmore\r\n")
            == "To: you@example.com\r\n\r\nBody\rmore\r\n")
    }

    /// Readers disagree on whether a bare line feed ends a header line, so a
    /// stripper that took one as a line end could read a Bcc field as body (or
    /// the other way round). A header line must end in CRLF; the body may not.
    @Test("refuses a header line that a bare line feed ends", arguments: [
        "From: me@example.com\nBcc: one@example.com,\n two@example.com\nTo: you@example.com\n\nBody\n",
        "To: you@example.com\r\nSubject: Draft\n\r\nBcc: hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\r\nSubject: x\n\nfoo\r\nBcc: hidden@example.com\r\n\r\nBody\r\n",
        "To: you@example.com\nSubject: x\n\nBody\r\nBcc: hidden@example.com\r\n",
        "To: you@example.com\r\nBcc: hidden@example.com\r\n\nBody\r\n"
    ])
    func refusesBareLFInHeader(raw: String) {
        #expect(throws: IMAPError.self) { try Self.strip(raw) }
    }

    @Test("keeps bare line feeds in the body")
    func keepsBareLFInBody() throws {
        #expect(try Self.strip("To: you@example.com\r\nBcc: a@example.com\r\n\r\nBody\nmore\n")
            == "To: you@example.com\r\n\r\nBody\nmore\n")
    }

    @Test("keeps bytes that are not UTF-8 unchanged")
    func keepsNonUTF8Bytes() throws {
        var raw = Data("Subject: caf".utf8)
        raw.append(0xE9)  // Latin-1 e-acute
        raw.append(contentsOf: Data("\r\nBcc: a@example.com\r\n\r\n".utf8))
        raw.append(0xFF)
        var expected = Data("Subject: caf".utf8)
        expected.append(0xE9)
        expected.append(contentsOf: Data("\r\n\r\n".utf8))
        expected.append(0xFF)
        #expect(try IMAPServer.removingBccFields(from: raw) == expected)
    }

    @Test("a kept copy loses exactly its Bcc header and nothing else")
    func keptCopyRoundTrip() throws {
        let kept = BccHeaderTests.email.constructContent(includeBccHeader: true)
        let bccLine = kept.components(separatedBy: "\r\n").first { $0.hasPrefix("Bcc: ") } ?? ""
        #expect(!bccLine.isEmpty)
        #expect(try Self.strip(kept) == kept.replacingOccurrences(of: bccLine + "\r\n", with: ""))
    }
}
