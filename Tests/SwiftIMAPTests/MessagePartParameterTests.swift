import Foundation
import Testing
@testable import SwiftMail
import NIOIMAPCore
import OrderedCollections

/// Tests for the Content-Type parameters of a message part: those a BODYSTRUCTURE
/// part's content type keeps, and how `contentTypeParameter(named:)` and
/// `declaredCharset` read them back.
@Suite(.timeLimit(.minutes(1)))
struct MessagePartParameterTests {

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
    func textPartReadsRFC2231ExtendedParameters() {
        // RFC 2231 lets a sender write any parameter in extended form, which a
        // server reports as written; Python's set_param with a tuple writes it.
        checkExtendedParameters(BodyStructure.Fields(
            parameters: ["charset*": "utf-8''gbk", "format*": "utf-8''flowed", "delsp*": "utf-8''yes"],
            id: nil, contentDescription: nil, encoding: nil, octetCount: 2))
    }

    @Test
    func textPartReadsRFC2231ContinuedParameters() {
        // Numbered continuations, any name case, an empty charset prefix, and a
        // plain parameter beside them.
        checkExtendedParameters(BodyStructure.Fields(
            parameters: ["Charset*0*": "utf-8''g", "Charset*1": "bk", "FORMAT*": "''flowed", "delsp": "yes"],
            id: nil, contentDescription: nil, encoding: nil, octetCount: 2))
    }

    private func checkExtendedParameters(_ fields: BodyStructure.Fields) {
        let bytes = Data([0xC2, 0xA9])
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "plain", lineCount: 1)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(kind: .text(text), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        guard parts.count == 1 else { return }
        var part = parts[0]
        part.data = bytes
        #expect(part.declaredCharset == "gbk")
        #expect(part.contentTypeParameter(named: "format") == "flowed")
        #expect(part.contentTypeParameter(named: "delsp") == "yes")
        let gbk = String.Encoding(mimeCharset: "gbk")
        #expect(gbk != nil)
        #expect(part.textContent == gbk.flatMap { String(data: bytes, encoding: $0) })
    }

    @Test
    func textPartReadsRFC2231PlainContinuedParameters() {
        // RFC 2231 §3 continuations need not be encoded: with no charset to
        // carry, a sender writes `name*0=` and `name*1=`, as Python's set_param
        // does for a long plain value.
        checkExtendedParameters(BodyStructure.Fields(
            parameters: [
                "charset*0": "g", "charset*1": "bk", "Format*0": "flo", "format*1": "wed", "delsp*0": "yes"
            ],
            id: nil, contentDescription: nil, encoding: nil, octetCount: 2))
    }

    @Test(arguments: [
        ["charset*": "iso-8859-1''iso-8859-1"],
        ["charset*0*": "''iso-8859", "charset*1": "-1"],
        ["charset*0": "iso-8859", "charset*1": "-1"]
    ])
    func mediaPartReadsRFC2231Charset(parameters: [String: String]) {
        // A charset is a parameter of more than text: application/xml carries
        // one too (RFC 7303), in any of its spellings.
        let bytes = Data([0x3C, 0x78, 0x3E, 0xE9, 0x3C, 0x2F, 0x78, 0x3E])
        let fields = BodyStructure.Fields(
            parameters: OrderedDictionary(uniqueKeysWithValues: parameters.sorted { $0.key < $1.key }),
            id: nil, contentDescription: nil, encoding: nil, octetCount: bytes.count)
        let structure = BodyStructure.singlepart(BodyStructure.Singlepart(
            kind: .basic(Media.MediaType(topLevel: "application", sub: "xml")), fields: fields))

        let parts = [MessagePart](structure)

        #expect(parts.count == 1)
        guard parts.count == 1 else { return }
        var part = parts[0]
        part.data = bytes
        #expect(part.declaredCharset?.lowercased() == "iso-8859-1")
        #expect(part.textContent == "<x>\u{00E9}</x>")
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
        ("text/plain; format=\"fl\\\"owed\"", "fl\"owed"),
        ("text/plain; format*=utf-8''flowed", "flowed"),
        ("text/plain; Format*0*=utf-8''flo; format*1=wed", "flowed"),
        ("text/plain; format*0=flo; format*1=wed", "flowed"),
        ("text/plain; format*0=\"flo\"; format*1*=%77ed", "flowed"),
        ("text/plain; format*0=flo; format*1*=%E9d; format=fixed", "fixed"),
        ("text/plain; format=fixed; format*=utf-8''flowed", "flowed"),
        ("text/plain; format*=no-such-charset''flowed; format=fixed", "fixed")
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
