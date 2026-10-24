import Foundation
import Testing
@testable import SwiftMail
import NIOIMAPCore

/// Tests for the Content-Type parameters a part built from BodyStructure keeps, and how they read back.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MessagePartContentTypeParameterTests {

    @Test
    func textPartKeepsTheParametersItsTextIsReadBy() {
        // RFC 3676: a format=flowed body is decoded by its format and delsp
        // parameters, as its charset decodes its bytes; other parameters stay out.
        let fields = BodyStructure.Fields(
            parameters: ["charset": "UTF-8", "format": "flowed", "delsp": "yes", "markup": "basic"],
            id: nil, contentDescription: nil, encoding: nil, octetCount: 0)
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        #expect(parts.first?.contentType == "text/plain; charset=UTF-8; format=flowed; delsp=yes")
        #expect(parts.first?.declaredCharset == "UTF-8")
    }

    @Test(arguments: [
        ["CHARSET", "FORMAT", "DELSP"],
        ["Charset", "Format", "DelSp"]
    ])
    func textPartParametersAreReadInAnyNameCase(names: [String]) throws {
        // A server reports parameter names as the sender wrote them.
        let typed = "日本語の下書き"
        let bytes = try #require(typed.data(using: .iso2022JP))
        let fields = BodyStructure.Fields(
            parameters: [names[0]: "iso-2022-jp", names[1]: "FLOWED", names[2]: "YES"],
            id: nil, contentDescription: nil, encoding: nil, octetCount: bytes.count)
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        guard parts.count == 1 else { return }
        var part = parts[0]
        part.data = bytes
        #expect(part.declaredCharset == "iso-2022-jp")
        #expect(part.contentTypeParameter(named: "format") == "FLOWED")
        #expect(part.contentTypeParameter(named: "delsp") == "YES")
        #expect(part.textContent == typed)
    }

    @Test
    func aParameterValueStaysOneParameter() {
        // BODYSTRUCTURE hands over a quoted value already unquoted; written back
        // bare, its `;` would end it and `charset=windows-1251` would read as a
        // charset the part never declared.
        let value = "flowed; charset=windows-1251"
        let fields = BodyStructure.Fields(
            parameters: ["format": value], id: nil, contentDescription: nil, encoding: nil, octetCount: 12)
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        guard parts.count == 1 else { return }
        var part = parts[0]
        let typed = "Привет"
        part.data = Data(typed.utf8)
        #expect(part.contentTypeParameter(named: "format") == value)
        #expect(part.declaredCharset == nil)
        #expect(part.textContent == typed)
    }

    @Test(arguments: [
        #"f\lowed"#,
        #"flo"wed"#,
        #"tail\"#,
        #"slash\"quote"#,
        "x; delsp=yes",
        " \t ",
        ""
    ])
    func aParameterValueReadsBackAsWritten(value: String) {
        // Quotes and backslashes are escaped in the quoted-string and unescaped
        // by the reader; the value never changes and never becomes a second parameter.
        let fields = BodyStructure.Fields(
            parameters: ["charset": "UTF-8", "format": value, "delsp": "no"],
            id: nil, contentDescription: nil, encoding: nil, octetCount: 9)
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        guard parts.count == 1 else { return }
        var part = parts[0]
        // The written value is RFC 2045 syntax on its own, whatever the reader accepts.
        let written = part.contentType
        let start = written.range(of: "; format=")
        let end = written.range(of: "; delsp=no", options: .backwards)
        #expect(start != nil && end != nil, "unexpected content type \(written)")
        if let start, let end, start.upperBound <= end.lowerBound {
            let emitted = written[start.upperBound..<end.lowerBound]
            #expect(Self.isMIMEParameterValue(emitted), "format=\(emitted) is not a token or a quoted-string")
        }
        part.data = Data("body text".utf8)
        #expect(part.contentTypeParameter(named: "FORMAT") == value)
        #expect(part.contentTypeParameter(named: "delsp") == "no")
        #expect(part.declaredCharset == "UTF-8")
        #expect(part.textContent == "body text")
    }

    /// RFC 2045 §5.1 `value := token / quoted-string`, checked independently of the
    /// reader: a token is one or more printable ASCII characters outside `tspecials`;
    /// a quoted-string (RFC 822) is quoted, with a backslash escaping the next
    /// character and no bare quote or line break inside.
    private static func isMIMEParameterValue(_ value: Substring) -> Bool {
        let tspecials = Set("()<>@,;:\\\"/[]?=".unicodeScalars)
        let scalars = Array(value.unicodeScalars)
        if !scalars.isEmpty, scalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && !tspecials.contains($0) }) {
            return true
        }
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else { return false }
        var index = 1
        while index < scalars.count - 1 {
            switch scalars[index] {
                case "\\":
                    guard index + 1 < scalars.count - 1 else { return false }
                    index += 2
                case "\"", "\r", "\n":
                    return false
                default:
                    index += 1
            }
        }
        return true
    }

    @Test(arguments: [
        ("text/plain; format=flowed", "flowed"),
        ("text/plain; Format=\"flowed\"", "flowed"),
        ("text/plain; format=flowed (a comment)", "flowed"),
        ("text/plain; format=\"fl\\\"owed\"", "fl\"owed")
    ])
    func contentTypeParameterReadsAMIMEParameter(contentType: String, expected: String) {
        let part = MessagePart(sectionString: "1", contentType: contentType, data: nil)
        #expect(part.contentTypeParameter(named: "format") == expected)
    }

    @Test(arguments: [
        "text/plain",
        "text/plain; x-note=\"keep; format=flowed\""
    ])
    func contentTypeParameterIsNilWhenAbsent(contentType: String) {
        // A `format=` inside another parameter's quoted value is that value's text.
        let part = MessagePart(sectionString: "1", contentType: contentType, data: nil)
        #expect(part.contentTypeParameter(named: "format") == nil)
    }
}
