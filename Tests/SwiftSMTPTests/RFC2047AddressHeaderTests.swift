// RFC2047AddressHeaderTests.swift
// An address formatted for a header — by `headerString()`, by `description`, or
// through `Message(email:).emlData()` — must carry its display name in a form
// the field body can actually hold, and must read back as the address it was
// built from.

import Foundation
import Testing
@testable import SwiftMail

@Suite("RFC 2047 address header formatting", .serialized, .timeLimit(.minutes(1)))
struct RFC2047AddressHeaderTests {

    /// Display names a header field body cannot carry literally: a CRLF pair,
    /// which *ends the field*; an embedded `"`, which closes the quoted-string
    /// and lets the rest be read as further address syntax; a `\`, which a
    /// conforming reader takes as a quoted-pair and drops; and ordinary
    /// non-ASCII text, which a header field must not carry as raw 8-bit.
    private static let unwritableNames = [
        "Bob\r\nBcc: attacker@example.com",
        #"Alice "The Boss" Smith"#,
        #"Team\Ops"#,
        "홍길동"
    ]

    /// Display names that are *literally* encoded-word-shaped — a user who typed
    /// `=?…?=` as their own name, not a name the library encoded. They are plain
    /// printable ASCII, so `headerString()` wraps them in a quoted-string rather
    /// than encoding them, and a quoted-string always carries a LITERAL: RFC 2047
    /// §5 forbids reading an encoded-word inside one. `init(_:)` must hand the
    /// literal back verbatim; MIME-decoding it silently corrupts the name and —
    /// for the third case — smuggles a CRLF the decode manufactures.
    private static let quotedEncodedWordShapedLiterals = [
        "=?UTF-8?B?SGVsbG8=?=",              // would decode to "Hello"
        "=?ISO-8859-1?Q?Caf=E9?=",          // would decode to "Café"
        "=?UTF-8?B?Qg0KQmNjOiBhQGIuY29t?="  // would decode to "B\r\nBcc: a@b.com"
    ]

    // MARK: - An encoded name is emitted bare

    @Test("An encoded display name is emitted bare, never inside a quoted-string")
    func encodedDisplayNameIsNeverQuoted() {
        for name in Self.unwritableNames {
            let header = EmailAddress(name: name, address: "bob@example.com").headerString()

            #expect(header.hasPrefix("=?UTF-8?B?"), "not encoded: \(header)")
            // RFC 2047 §5: an encoded-word MUST NOT appear inside a
            // quoted-string. Wrapping one in quotes is not a cosmetic slip — a
            // reader that honours the rule hands the literal `=?UTF-8?B?…?=`
            // back to the user instead of the name.
            #expect(!header.hasPrefix("\""), "encoded-word inside a quoted-string: \(header)")
            #expect(!header.contains("\"=?"), "encoded-word inside a quoted-string: \(header)")
            #expect(header.hasSuffix(" <bob@example.com>"))
        }
    }

    @Test("description formats an address the same way a header field needs it")
    func descriptionIsHeaderSafe() {
        for name in Self.unwritableNames {
            let address = EmailAddress(name: name, address: "bob@example.com")

            #expect(address.description == address.headerString())
            #expect(address.description.allSatisfy { $0.isASCII }, "8-bit in a header: \(address.description)")
            #expect(!address.description.unicodeScalars.contains { $0 == "\r" || $0 == "\n" })
        }
    }

    @Test("An address survives the round trip through its own string form")
    func addressStringRoundTrips() {
        let addresses = Self.unwritableNames.map { EmailAddress(name: $0, address: "bob@example.com") } + [
            EmailAddress(name: "Smith, Alice", address: "alice@example.com"),
            EmailAddress(name: "Alice", address: "alice@example.com"),
            // A quoted encoded-word-shaped literal must round-trip too — the
            // quoted branch must not decode it.
            EmailAddress(name: "=?UTF-8?B?SGVsbG8=?=", address: "literal@example.com"),
            EmailAddress(address: "plain@example.com")
        ]

        for address in addresses {
            let restored = EmailAddress(address.description)
            #expect(restored?.address == address.address, "address lost: \(address.description)")
            #expect(restored?.name == address.name, "name lost: \(address.description)")
        }
    }

    // MARK: - A quoted-string always carries a literal (RFC 2047 §5)

    @Test("An encoded-word-shaped literal in a quoted display name is preserved, never decoded")
    func quotedLiteralEncodedWordIsNotDecoded() {
        for literal in Self.quotedEncodedWordShapedLiterals {
            let address = EmailAddress(name: literal, address: "bob@example.com")

            // A plain-ASCII special-char name is wrapped in a quoted-string, not
            // encoded — so the literal is carried inside the quotes.
            #expect(address.description.hasPrefix("\""), "expected a quoted-string: \(address.description)")

            let restored = EmailAddress(address.description)
            #expect(restored?.name == literal, "literal decoded or lost: \(String(describing: restored?.name))")
            #expect(restored?.address == "bob@example.com")
            // The third case decodes to a CRLF-bearing string; if the branch ever
            // decoded again, the reconstructed name would carry that CRLF.
            #expect(!(restored?.name?.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } ?? false),
                    "decode reintroduced a CRLF: \(String(describing: restored?.name))")
        }

        // Two-sided pin: a BARE encoded-word (the wire form of a non-ASCII name)
        // MUST still decode — the quoted-literal rule must not disarm it.
        let korean = EmailAddress(name: "홍길동", address: "bob@example.com")
        #expect(!korean.description.hasPrefix("\""), "a non-ASCII name must be bare: \(korean.description)")
        #expect(EmailAddress(korean.description)?.name == "홍길동")
    }

    // MARK: - Message(email:) → emlData()

    @Test("A display name cannot forge a header field in the serialized EML")
    func emlHeaderBlockCannotBeForged() throws {
        let benign = try Self.headerFieldNames(senderNamed: "Bob")
        #expect(benign.contains("From"))

        for name in Self.unwritableNames {
            let fields = try Self.headerFieldNames(senderNamed: name)
            // A hostile display name changes the *value* of `From:` and nothing
            // else: same fields, same order, still one `From:`.
            #expect(fields == benign, "header block changed for \(name.debugDescription): \(fields)")
            #expect(!fields.contains { $0.lowercased() == "bcc" })
        }
    }

    @Test("The serialized From: value re-parses to exactly the address it was built from")
    func emlFromValueReparsesToOneAddress() throws {
        for name in Self.unwritableNames {
            let fromFieldBody = try Self.fromFieldBody(senderNamed: name)
            let value = try #require(fromFieldBody, "no From: line for \(name.debugDescription)")

            // Exactly one addr-spec — a smuggled second address brings its own `@`.
            #expect(value.filter { $0 == "@" }.count == 1, "more than one address in From: \(value)")
            #expect(value.allSatisfy { $0.isASCII }, "8-bit in a header: \(value)")
            #expect(!value.hasPrefix("\""), "name carried in a quoted-string: \(value)")

            let parsed = try #require(EmailAddress(value), "unparsable From: \(value)")
            #expect(parsed.address == "bob@example.com")
            #expect(parsed.name == name, "name lost: \(String(describing: parsed.name))")
        }
    }

    @Test("Email → Message → Email keeps a non-ASCII display name")
    func conversionRoundTripKeepsTheName() throws {
        let email = Email(
            sender: EmailAddress(name: "홍길동", address: "hong@example.com"),
            recipients: [EmailAddress(name: #"Kim "Chul" Soo"#, address: "kim@example.com")],
            subject: "안녕하세요",
            textBody: "body"
        )

        let restored = try Email(message: Message(email: email))

        #expect(restored.sender.name == "홍길동")
        #expect(restored.sender.address == "hong@example.com")
        #expect(restored.recipients.first?.name == #"Kim "Chul" Soo"#)
        #expect(restored.recipients.first?.address == "kim@example.com")
    }

    // MARK: - Helpers

    private static func eml(senderNamed name: String) throws -> String {
        let email = Email(
            sender: EmailAddress(name: name, address: "bob@example.com"),
            recipients: [EmailAddress(address: "you@example.com")],
            subject: "Hello",
            textBody: "body"
        )
        let data = try Message(email: email).emlData()
        // Failable on purpose: a header field body has to be 7-bit ASCII, so
        // anything that is not valid UTF-8 is a defect, not something to paper
        // over with replacement characters.
        return try #require(String(bytes: data, encoding: .utf8), "EML is not valid UTF-8")
    }

    /// The field names of the EML's header block, in order — every line up to
    /// the blank line that ends it, minus folded continuations.
    private static func headerFieldNames(senderNamed name: String) throws -> [String] {
        try eml(senderNamed: name)
            .components(separatedBy: "\r\n")
            .prefix { !$0.isEmpty }
            .compactMap { line in
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                      let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[..<colon])
            }
    }

    private static func fromFieldBody(senderNamed name: String) throws -> String? {
        try eml(senderNamed: name)
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("From: ") }
            .map { String($0.dropFirst("From: ".count)) }
    }
}
