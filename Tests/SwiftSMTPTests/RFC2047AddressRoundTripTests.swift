// RFC2047AddressRoundTripTests.swift
// Regression coverage for parsing and repeatedly serializing structured address
// fields that contain encoded display names.

import Foundation
import Testing
@testable import SwiftMail

@Suite("RFC 2047 address parse and serialization", .serialized, .timeLimit(.minutes(1)))
struct RFC2047AddressRoundTripTests {

    @Test("Quoted-pairs recover their literal display-name characters")
    func quotedPairsRoundTripThroughEML() throws {
        let cases = [
            (#""Alice \"Boss\"" <alice@example.com>"#, #"Alice "Boss""#),
            (#""Team\\Ops" <alice@example.com>"#, #"Team\Ops"#)
        ]

        for (from, expectedName) in cases {
            let eml = "From: \(from)\r\nContent-Type: text/plain\r\n\r\nbody\r\n"
            let parsed = try Message(emlData: Data(eml.utf8))
            let firstEmail = try Email(message: parsed)
            let reparsed = try Message(emlData: parsed.emlData())
            let secondEmail = try Email(message: reparsed)

            #expect(firstEmail.sender.name == expectedName)
            #expect(secondEmail.sender.name == expectedName)
            #expect(secondEmail.sender.address == "alice@example.com")
        }
    }

    @Test("Trailing comments after an angle address remain convertible")
    func trailingCFWSIsAccepted() throws {
        let header = MessageInfo(
            sequenceNumber: SequenceNumber(0),
            from: "Alice <alice@example.com> (work)"
        )
        let restored = try Email(message: Message(header: header, parts: []))

        #expect(restored.sender.name == "Alice")
        #expect(restored.sender.address == "alice@example.com")
        #expect(EmailAddress("Alice <alice@example.com> (outer (nested))") != nil)
        #expect(EmailAddress("Alice <alice@example.com> (work > remote)") != nil)
        #expect(EmailAddress("Alice <alice@example.com> arbitrary") == nil)
    }

    @Test("A decoded display name cannot inject a field on a second serialization")
    func parsedMessageCannotInjectOnReserialization() throws {
        let name = "Bob\r\nBcc: attacker@example.com\r\nX-Ignore:"
        let original = Self.email(senderName: name)
        let firstData = try Message(email: original).emlData()
        let parsed = try Message(emlData: firstData)
        let secondData = try parsed.emlData()

        let firstNames = Self.headerNames(in: firstData)
        let secondNames = Self.headerNames(in: secondData)
        #expect(firstNames.filter { $0 == "From" }.count == 1)
        #expect(secondNames.filter { $0 == "From" }.count == 1)
        #expect(!firstNames.contains("Bcc"))
        #expect(!secondNames.contains("Bcc"))
        #expect(!secondNames.contains("X-Ignore"))

        let restored = try Email(message: try Message(emlData: secondData))
        #expect(restored.sender.name == name)
        #expect(restored.sender.address == "real@example.com")
    }

    @Test("Display-name angle brackets cannot replace the real sender")
    func displayNameCannotReplaceAddrSpec() throws {
        let name = "홍<evil@example.com>"
        let original = Self.email(senderName: name)
        let parsed = try Message(emlData: Message(email: original).emlData())
        let restored = try Email(message: parsed)

        #expect(restored.sender.name == name)
        #expect(restored.sender.address == "real@example.com")
    }

    @Test("Long folded display names survive direct and EML round trips")
    func longDisplayNamesRoundTrip() throws {
        let name = String(repeating: "한", count: 16)
        let address = EmailAddress(name: name, address: "long@example.com")
        let direct = try #require(EmailAddress(address.description))

        #expect(direct == address)

        let original = Email(
            sender: address,
            recipients: [address],
            ccRecipients: [address],
            bccRecipients: [address],
            subject: "Long name",
            textBody: "body"
        )
        let parsed = try Message(emlData: Message(email: original).emlData())
        let restored = try Email(message: parsed)

        #expect(restored.sender == address)
        #expect(restored.recipients == [address])
        #expect(restored.ccRecipients == [address])
        #expect(restored.bccRecipients == [address])
    }

    @Test("Whitespace between adjacent encoded-words is ignored after unfolding")
    func adjacentEncodedWordWhitespaceIsIgnored() throws {
        let name = String(repeating: "한", count: 16)
        let words = name.rfc2047EncodedHeader().components(separatedBy: "\r\n ")
        #expect(words.count > 1)

        let eml = """
        From: sender@example.com\r
        Subject: \(words.joined(separator: "\r\n "))\r
        Content-Type: text/plain\r
        \r
        body\r
        """
        let parsed = try Message(emlData: Data(eml.utf8))

        #expect(parsed.subject == name)
    }

    @Test("Encoded-word substrings inside phrase atoms remain literal")
    func partialEncodedWordTokenRemainsLiteral() throws {
        let literals = [
            "pre=?UTF-8?B?SGVsbG8=?=post",
            "pre=?UTF-8?B?Qg0KQmNjOiBhQGIuY29t?=post"
        ]

        for literal in literals {
            let value = "\(literal) <bob@example.com>"
            let direct = try #require(EmailAddress(value))
            #expect(direct.name == literal)
            #expect(direct.address == "bob@example.com")

            let eml = "From: \(value)\r\nContent-Type: text/plain\r\n\r\nbody\r\n"
            let parsed = try Message(emlData: Data(eml.utf8))
            let restored = try Email(message: parsed)
            #expect(restored.sender.name == literal)
            #expect(!restored.sender.name!.contains("\r"))
            #expect(!restored.sender.name!.contains("\n"))
        }
    }

    private static func email(senderName: String) -> Email {
        Email(
            sender: EmailAddress(name: senderName, address: "real@example.com"),
            recipients: [EmailAddress(address: "you@example.com")],
            subject: "Hello",
            textBody: "body"
        )
    }

    private static func headerNames(in data: Data) -> [String] {
        guard let eml = String(data: data, encoding: .utf8) else { return [] }
        return eml.components(separatedBy: "\r\n")
            .prefix { !$0.isEmpty }
            .compactMap { line in
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                      let colon = line.firstIndex(of: ":") else { return nil }
                return String(line[..<colon])
            }
    }
}
