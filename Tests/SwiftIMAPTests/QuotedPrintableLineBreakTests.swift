import Foundation
import Testing
@testable import SwiftMail

/// A quoted-printable body carries its line breaks as CRLF (RFC 2045 §6.7 rule 4),
/// so every line ending in the source must become exactly one CRLF in the output.
/// A line ending directly followed by a combining mark, a variation selector or an
/// emoji modifier must not be left out of that: the default search compares
/// composed character sequences and does not find such a line ending.
@Suite("Quoted-printable line breaks before a mark", .tags(.encoding))
struct QuotedPrintableLineBreakTests {

    enum LineEnding: String, CaseIterable {
        case crlf = "\r\n", lineFeed = "\n", carriageReturn = "\r"
    }

    enum Mark: String, CaseIterable {
        case combiningAcute = "\u{0301}", variationSelector16 = "\u{FE0F}", skinToneModifier = "\u{1F3FB}"
    }

    @Test("Every line ending before a mark becomes one CRLF line break",
          arguments: LineEnding.allCases, Mark.allCases)
    func lineEndingBeforeMark(_ ending: LineEnding, _ mark: Mark) {
        let source = "a" + ending.rawValue + mark.rawValue + "b"
        let encodedMark = mark.rawValue.utf8.map { String(format: "=%02X", $0) }.joined()
        let expected = "a\r\n" + encodedMark + "b"
        #expect(Array(source.quotedPrintableEncoded().utf8) == Array(expected.utf8))
    }
}
