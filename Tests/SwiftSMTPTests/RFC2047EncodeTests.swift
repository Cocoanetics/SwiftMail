// RFC2047EncodeTests.swift
// Verifies RFC 2047 encoded-word ENCODING of non-ASCII header values and that
// the output round-trips through `decodeMIMEHeader()`.

import Foundation
import Testing
@testable import SwiftMail

@Suite("RFC 2047 header encoding")
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
