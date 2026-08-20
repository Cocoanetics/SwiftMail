// RFC2047EncodeTests.swift
// Verifies RFC 2047 encoded-word ENCODING of non-ASCII header values and that
// the output round-trips through `decodeMIMEHeader()`.

import Foundation
import Testing
@testable import SwiftMail

@Suite("RFC 2047 header encoding", .serialized, .timeLimit(.minutes(1)))
struct RFC2047EncodeTests {

    // MARK: - String.rfc2047EncodedHeader()

    @Test("Pure-ASCII subject is returned unchanged")
    func asciiPassthrough() {
        #expect("Hello, world!".rfc2047EncodedHeader() == "Hello, world!")
        #expect("Re: Q3 report".rfc2047EncodedHeader() == "Re: Q3 report")
        #expect("".rfc2047EncodedHeader() == "")
    }

    @Test("Korean subject encodes to pure ASCII and round-trips")
    func koreanRoundTrip() {
        let subject = "가입정보 변경 안내"
        let encoded = subject.rfc2047EncodedHeader()

        // Header bytes must be 7-bit clean.
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(encoded.hasPrefix("=?UTF-8?B?"))
        // The raw Korean must NOT appear literally in the header.
        #expect(!encoded.contains("가"))
        // And it decodes back to exactly the original.
        #expect(encoded.decodeMIMEHeader() == subject)
    }

    @Test("Mixed ASCII + non-ASCII round-trips")
    func mixedRoundTrip() {
        let subject = "Re: 회의 일정 (Q3) 안내 — 確認"
        let encoded = subject.rfc2047EncodedHeader()
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(encoded.decodeMIMEHeader() == subject)
    }

    @Test("Long non-ASCII subject folds into multiple ≤75-octet encoded-words and round-trips")
    func longSubjectFolds() {
        // ~40 Korean syllables → must exceed one 45-byte encoded-word.
        let subject = String(repeating: "한국어제목", count: 8)
        let encoded = subject.rfc2047EncodedHeader()

        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(encoded.decodeMIMEHeader() == subject)

        // Every individual encoded-word stays within RFC 2047 §2's 75-octet limit.
        let words = encoded
            .components(separatedBy: "\r\n ")
            .flatMap { $0.split(separator: " ").map(String.init) }
        #expect(words.count > 1, "expected the subject to fold into multiple words")
        for word in words {
            #expect(word.utf8.count <= 75, "encoded-word exceeds 75 octets: \(word)")
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
        }
    }

    @Test("Each folded word decodes independently (no multibyte char split across words)")
    func wordsDecodeIndependently() {
        let subject = String(repeating: "테스트", count: 10)
        let encoded = subject.rfc2047EncodedHeader()
        let words = encoded.components(separatedBy: "\r\n ")
        // Decoding each word in isolation must yield valid UTF-8, and the
        // concatenation must reproduce the original — proving no character's
        // bytes were split across the word boundary.
        let rejoined = words.map { $0.decodeMIMEHeader() }.joined()
        #expect(rejoined == subject)
    }

    // MARK: - EmailAddress.headerString()

    @Test("ASCII display name behaves like description")
    func asciiDisplayName() {
        let addr = EmailAddress(name: "Alice Smith", address: "alice@example.com")
        #expect(addr.headerString() == "Alice Smith <alice@example.com>")
        let comma = EmailAddress(name: "Smith, Alice", address: "alice@example.com")
        #expect(comma.headerString() == "\"Smith, Alice\" <alice@example.com>")
    }

    @Test("Non-ASCII display name is RFC 2047-encoded, address kept literal")
    func nonAsciiDisplayName() {
        let addr = EmailAddress(name: "홍길동", address: "hong@example.com")
        let header = addr.headerString()
        #expect(header.allSatisfy { $0.isASCII })
        #expect(header.hasSuffix(" <hong@example.com>"))
        // Name portion (before the address) decodes back to the original.
        let namePart = String(header.dropLast(" <hong@example.com>".count))
        #expect(namePart.decodeMIMEHeader() == "홍길동")
    }

    // MARK: - constructContent integration

    @Test("constructContent emits an encoded Subject, not raw 8-bit")
    func constructContentEncodesSubject() {
        let email = Email(
            sender: EmailAddress(address: "me@example.com"),
            recipients: [EmailAddress(address: "you@example.com")],
            subject: "테스트 제목",
            textBody: "본문",
            htmlBody: nil
        )
        let content = email.constructContent()

        // The Subject header line carries an encoded-word, not the raw Korean.
        #expect(content.contains("Subject: =?UTF-8?B?"))
        #expect(!content.contains("Subject: 테스트"))

        // Extract the Subject line and confirm it decodes to the original.
        let subjectLine = content
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("Subject: ") }
        #expect(subjectLine != nil)
        if let subjectLine {
            let value = String(subjectLine.dropFirst("Subject: ".count))
            #expect(value.decodeMIMEHeader() == "테스트 제목")
        }
    }
}

/// Values that RFC 5322 §2.2 does not allow to appear literally in a header
/// field body, and the RFC 2047 §2 75-octet ceiling. Kept in a second suite so
/// neither type body grows past SwiftLint's `type_body_length` limit.
@Suite("RFC 2047 header field body safety", .serialized, .timeLimit(.minutes(1)))
struct RFC2047HeaderFieldBodyTests {

    /// Every scalar a field body cannot carry literally: the C0 controls and
    /// DEL. HTAB is excluded deliberately — it is WSP, which RFC 5322 §3.2.5
    /// allows literally in an unstructured field body.
    private static let forbiddenScalars: [Unicode.Scalar] =
        ((0x00 as UInt32)...(0x1F as UInt32)).filter { $0 != 0x09 }.compactMap(Unicode.Scalar.init)
            + [Unicode.Scalar(0x7F)!]

    /// The exact words this encoder produced for the two values in
    /// ``alreadyCorrectValuesFoldByteIdentically``. Both values are built from
    /// grapheme clusters that fit inside the 45-byte per-word budget, so every
    /// word they produced was already inside RFC 2047 §2's ceiling and none of
    /// them had any reason to change.
    private static let grinningWord =
        "=?UTF-8?B?8J+YgPCfmIDwn5iA8J+YgPCfmIDwn5iA8J+YgPCfmIDwn5iA8J+YgA==?="
    private static let thumbsUpWord = "=?UTF-8?B?8J+RjfCfj70=?="
    private static let familyWord = "=?UTF-8?B?8J+RqOKAjfCfkanigI3wn5Gn4oCN8J+Rpg==?="

    // MARK: - Trigger

    @Test("Every C0 control and DEL is encoded and round-trips")
    func c0AndDelAreEncoded() {
        for scalar in Self.forbiddenScalars {
            let value = "a\(String(scalar))b"
            let encoded = value.rfc2047EncodedHeader()
            let name = String(format: "U+%04X", scalar.value)

            #expect(!encoded.unicodeScalars.contains(scalar), "\(name) survived literally")
            #expect(encoded.hasPrefix("=?UTF-8?B?"), "\(name) was not encoded")
            #expect(encoded.decodeMIMEHeader() == value, "\(name) did not round-trip")
        }
    }

    @Test("Benign field bodies are returned byte-identical")
    func benignValuesAreUnchanged() {
        // HTAB is legal WSP and must not trigger encoding.
        #expect("a b\tc".rfc2047EncodedHeader() == "a b\tc")
        #expect("Re: Q3 report".rfc2047EncodedHeader() == "Re: Q3 report")
        // `"` and `\` are ordinary printable text in an unstructured field body;
        // only the quoted-string of a display name has to care about them.
        #expect(#""quoted" and \back\"#.rfc2047EncodedHeader() == #""quoted" and \back\"#)
    }

    // MARK: - 75-octet ceiling

    @Test("A grapheme cluster wider than one word cannot produce an oversized encoded-word")
    func wideGraphemeClusterStaysWithinCeiling() {
        // "a" followed by 23 combining acute accents is a single extended
        // grapheme cluster of 47 UTF-8 bytes; flushing only between clusters
        // emits it as one 12 + 4*ceil(47/3) = 76-octet word.
        let value = "a" + String(repeating: "\u{0301}", count: 23)
        let encoded = value.rfc2047EncodedHeader()
        let words = encoded.components(separatedBy: "\r\n ")

        #expect(words.count > 1, "expected the value to fold into multiple words")
        for word in words {
            #expect(word.utf8.count <= 75, "encoded-word is \(word.utf8.count) octets, over the 75 limit")
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
        }
        // Scalar-exact: splitting between scalars must not drop, reorder or
        // re-normalize anything.
        #expect(Array(encoded.decodeMIMEHeader().unicodeScalars) == Array(value.unicodeScalars))
    }

    @Test("An oversized cluster is split between scalars and bounded at 72 octets")
    func oversizedClusterIsBoundedAtSeventyTwoOctets() {
        // The same 47-byte cluster, held to the tighter bound the per-scalar
        // fallback actually guarantees: a scalar is at most 4 bytes, so a chunk
        // built out of scalars never exceeds the 45-byte budget and the widest
        // word it can produce is 12 + 4*ceil(45/3) = 72 octets.
        let value = "a" + String(repeating: "\u{0301}", count: 23)
        let words = value.rfc2047EncodedHeader().components(separatedBy: "\r\n ")

        #expect(words.count == 2)
        for word in words {
            #expect(word.utf8.count <= 72, "encoded-word is \(word.utf8.count) octets, over the 72 bound")
        }
    }

    @Test("A value that already folded within the ceiling folds byte-identically")
    func alreadyCorrectValuesFoldByteIdentically() {
        // Ten grinning faces (4 bytes each) then one thumbs-up with a skin-tone
        // modifier — a two-scalar, 8-byte cluster. Splitting on scalars puts the
        // word boundary *inside* that cluster; splitting on clusters does not.
        let thumbsUp = String(repeating: "😀", count: 10) + "👍🏽"
        let expectedThumbsUp = [Self.grinningWord, Self.thumbsUpWord].joined(separator: "\r\n ")
        #expect(thumbsUp.rfc2047EncodedHeader() == expectedThumbsUp)

        // A ZWJ family sequence: one 25-byte cluster of seven scalars.
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 3)
        let expectedFamily = [Self.familyWord, Self.familyWord, Self.familyWord].joined(separator: "\r\n ")
        #expect(family.rfc2047EncodedHeader() == expectedFamily)

        // Neither was ever over the ceiling, so neither had anything to fix.
        for encoded in [expectedThumbsUp, expectedFamily] {
            for word in encoded.components(separatedBy: "\r\n ") {
                #expect(word.utf8.count <= 75, "encoded-word is \(word.utf8.count) octets, over the 75 limit")
            }
        }
        #expect(expectedThumbsUp.decodeMIMEHeader() == thumbsUp)
        #expect(expectedFamily.decodeMIMEHeader() == family)
    }

    // MARK: - constructContent integration

    @Test("A CRLF-bearing subject cannot open a second header field")
    func subjectCannotInjectAHeaderField() {
        let injected = "Hi\r\nBcc: attacker@example.com"
        let email = Email(
            sender: EmailAddress(address: "me@example.com"),
            recipients: [EmailAddress(address: "you@example.com")],
            subject: injected,
            textBody: "body"
        )
        let lines = email.constructContent().components(separatedBy: "\r\n")

        #expect(lines.filter { $0.hasPrefix("Subject: ") }.count == 1)
        #expect(!lines.contains { $0.lowercased().hasPrefix("bcc:") })

        let subjectLine = lines.first { $0.hasPrefix("Subject: ") }
        #expect(subjectLine != nil)
        guard let subjectLine else { return }
        // Nothing is dropped: the recipient still sees exactly what was written.
        #expect(String(subjectLine.dropFirst("Subject: ".count)).decodeMIMEHeader() == injected)
    }

    @Test("A CRLF-bearing display name cannot open a second header field")
    func displayNameCannotInjectAHeaderField() {
        let injected = "Bob\r\nBcc: attacker@example.com"
        let email = Email(
            sender: EmailAddress(address: "me@example.com"),
            recipients: [EmailAddress(name: injected, address: "bob@example.com")],
            subject: "Hello",
            textBody: "body"
        )
        let lines = email.constructContent().components(separatedBy: "\r\n")

        #expect(lines.filter { $0.hasPrefix("To: ") }.count == 1)
        #expect(!lines.contains { $0.lowercased().hasPrefix("bcc:") })

        let toLine = lines.first { $0.hasPrefix("To: ") }
        #expect(toLine != nil)
        guard let toLine else { return }
        let value = String(toLine.dropFirst("To: ".count))
        #expect(value.hasSuffix(" <bob@example.com>"))
        #expect(Self.recoveredDisplayName(from: value) == injected)
    }

    @Test("A display name containing a quote cannot escape the quoted-string")
    func displayNameQuoteCannotEscapeTheQuotedString() {
        let name = #"Alice "The Boss" Smith"#
        let header = EmailAddress(name: name, address: "alice@example.com").headerString()

        #expect(header.hasSuffix(" <alice@example.com>"))
        #expect(Self.recoveredDisplayName(from: header) == name)
    }

    @Test("A display name containing a backslash keeps its literal text")
    func displayNameBackslashKeepsItsLiteralText() {
        let name = #"Team\Ops"#
        let header = EmailAddress(name: name, address: "ops@example.com").headerString()

        #expect(header.hasSuffix(" <ops@example.com>"))
        #expect(Self.recoveredDisplayName(from: header) == name)
    }

    /// Recover the display name the way a *conforming* reader would: a
    /// quoted-string is unescaped per RFC 5322 §3.2.4 (a `\` escapes the next
    /// character), an unquoted phrase is taken as-is, and either result is then
    /// RFC 2047-decoded. Deliberately independent of ``EmailAddress/init(_:)``,
    /// which does not implement quoted-pairs and so would report a name that a
    /// real recipient never sees.
    private static func recoveredDisplayName(from header: String) -> String? {
        guard let addressStart = header.lastIndex(of: "<") else { return nil }
        let phrase = header[..<addressStart].trimmingCharacters(in: .whitespaces)
        guard phrase.hasPrefix("\"") else { return phrase.decodeMIMEHeader() }

        var recovered = ""
        var isEscaped = false
        for character in phrase.dropFirst() {
            if isEscaped {
                recovered.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return recovered.decodeMIMEHeader()
            } else {
                recovered.append(character)
            }
        }
        return nil // unterminated quoted-string
    }
}
