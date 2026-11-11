// AddressListFoldingTests+Octets.swift
// Address-list folding counts octets, not characters, and folds every
// address-list field the EML writer emits, From and Reply-To included.

import Foundation
import Testing
@testable import SwiftMail

extension AddressListFoldingTests {
    /// An addr-spec of exactly `octets` ASCII octets at example.com.
    static func asciiAddress(_ octets: Int) -> EmailAddress {
        let domain = "@example.com"
        return EmailAddress(address: fill("a", octets - domain.utf8.count) + domain)
    }

    /// A UTF-8 local part: RFC 6532 keeps it as it is, so it is written as raw
    /// UTF-8 of 15 octets but only 5 characters. A display name that isn't
    /// ASCII is encoded instead, so only an addr-spec carries raw UTF-8.
    static let wideLocalPart = String(repeating: "한", count: 5)

    /// A list of two addresses, one holding raw UTF-8, where the other one's
    /// length decides whether the second address shares a line with the first.
    struct OctetCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        /// The address holding raw UTF-8.
        let wide: EmailAddress
        /// Whether the ASCII address comes first, so the fold is judged on
        /// `wide`'s first line; otherwise it comes after `wide`, and is judged
        /// against the octets `wide` left on its last line.
        let asciiFirst: Bool
        /// Whether `wide` is written with folds of its own.
        let hasOwnFolds: Bool
    }

    static let octetCases: [OctetCase] = [
        OctetCase(testDescription: "in the address that would join the line",
                  wide: EmailAddress(address: "\(wideLocalPart)@example.com"),
                  asciiFirst: true, hasOwnFolds: false),
        OctetCase(testDescription: "in an address that fit on its line",
                  wide: EmailAddress(address: "\(wideLocalPart)@example.com"),
                  asciiFirst: false, hasOwnFolds: false),
        // Sixteen three-octet characters fill one 45-octet encoded-word and
        // start a second, so the name is written on two lines and the
        // address follows on the second.
        OctetCase(testDescription: "in the last line of an address with folds of its own",
                  wide: EmailAddress(name: String(repeating: "한", count: 16),
                                     address: "\(wideLocalPart)@example.com"),
                  asciiFirst: false, hasOwnFolds: true)
    ]

    @Test("Raw UTF-8 in an address is counted in octets: a line can end at exactly 78, and one octet more folds",
          arguments: Self.octetCases)
    func rawUTF8IsCountedInOctets(_ fixture: OctetCase) throws {
        let wide = fixture.wide.headerString()
        let wideLines = wide.components(separatedBy: "\r\n")
        #expect((wideLines.count > 1) == fixture.hasOwnFolds, "setup: \(wideLines)")
        // The line the fold is judged on holds raw UTF-8, so counting its
        // characters instead of its octets would keep a line that is too long.
        let judged = fixture.asciiFirst ? wideLines[0] : wideLines[wideLines.count - 1]
        #expect(judged.utf8.count > judged.count, "setup: \(judged) must hold raw UTF-8")

        // The ASCII address length that ends the shared line at exactly 78 octets.
        let width = AddressFormatter.foldedLineLength
        let fits: Int
        if fixture.asciiFirst {
            fits = width - "To: ".utf8.count - ", ".utf8.count - wide.utf8.count
        } else {
            let lastLine = ("To: " + wide + ",").components(separatedBy: "\r\n").last ?? ""
            fits = width - lastLine.utf8.count - " ".utf8.count
        }

        for length in [fits, fits + 1] {
            let ascii = Self.asciiAddress(length)
            let recipients = fixture.asciiFirst ? [ascii, fixture.wide] : [fixture.wide, ascii]
            let separator = length == fits ? ", " : ",\r\n "
            let expected = ("To: " + recipients.map { $0.headerString() }.joined(separator: separator))
                .components(separatedBy: "\r\n")
            let email = Email(
                sender: EmailAddress(address: "sender@example.com"),
                recipients: recipients,
                subject: "Hi",
                textBody: "body"
            )
            let sent = email.constructContent()
            let eml = try #require(String(data: try Message(email: email).emlData(), encoding: .utf8))
            for content in [sent, eml] {
                let lines = Self.headerLines(of: content)
                #expect(lines.allSatisfy { $0.utf8.count <= width }, "\(lines)")
                let start = try #require(lines.firstIndex { $0.hasPrefix("To: ") })
                #expect(Array(lines[start...].prefix(expected.count)) == expected)
                let restored = try Email(message: Message(emlData: Data(content.utf8)))
                #expect(restored.recipients == recipients)
            }
        }
    }

    @Test("A fold before an address starting with a combining mark passes the send and kept-copy checks")
    func foldBeforeACombiningMarkIsAccepted() throws {
        // "To: " and the first address with its comma take 66 octets, so the
        // 15-octet second address is folded onto a line of its own, and the
        // fold's space is followed by U+0301.
        let first = Self.asciiAddress(65)
        let marked = EmailAddress(address: "\u{0301}x@example.com")
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [first, marked],
            subject: "Hi",
            textBody: "body"
        )
        let to = try #require(email.headerFields(includeBccHeader: false).first { $0.name == "To" })
        #expect(Array(to.value.utf8) == Array("\(first.address),\r\n \(marked.address)".utf8))

        try SMTPServer.checkHeaderFields(email.preparedContent().headerFields)
        let keptCopy = try email.keptCopyContent(use8BitMIME: false)

        let restored = try Email(message: Message(emlData: Data(keptCopy.utf8)))
        #expect(restored.recipients == email.recipients)
    }

    /// A header naming `entries` in the address-list field `name`, from one
    /// other sender, so the EML writer writes the field exactly once.
    static func header(naming entries: [AddressListEntry], in name: String) -> MessageInfo {
        var header = MessageInfo(sequenceNumber: SequenceNumber(0), from: "sender@example.com")
        switch name {
            case "From": header.fromAddresses = entries
            case "Reply-To": header.replyToAddresses = entries
            case "To": header.toAddresses = entries
            case "Cc": header.ccAddresses = entries
            default: header.bccAddresses = entries
        }
        return header
    }

    /// The parsed field `name` of `header`, as ``header(naming:in:)`` sets it.
    static func entries(in name: String, of header: MessageInfo) -> [AddressListEntry] {
        switch name {
            case "From": header.fromAddresses
            case "Reply-To": header.replyToAddresses
            case "To": header.toAddresses
            case "Cc": header.ccAddresses
            default: header.bccAddresses
        }
    }

    @Test("A long From and Reply-To written to EML are folded and parse back to the same addresses",
          arguments: ["From", "Reply-To"])
    func emlSenderListsAreFoldedAndRoundTrip(_ name: String) throws {
        let entries = Self.addresses(40, prefix: "list").map(AddressListEntry.mailbox)
        let data = try Message(header: Self.header(naming: entries, in: name), parts: []).emlData()
        let content = try #require(String(data: data, encoding: .utf8))

        #expect(Self.headerLines(of: content).allSatisfy { $0.utf8.count <= AddressFormatter.foldedLineLength })
        #expect(Self.body(of: name, in: content) == [Self.unfoldedList(entries.map(\.description))])

        let parsed = try Message(emlData: data)
        #expect(Self.entries(in: name, of: parsed.header) == entries)
    }

    @Test("The EML writer counts the From and Reply-To field names toward the first line",
          arguments: ["From", "Reply-To"])
    func emlWriterCountsTheSenderFieldNames(_ name: String) throws {
        let next = EmailAddress(address: "b@example.com")
        // "<name>: " + lead + ", " + next is 78 octets when lead is `fits` long.
        let fits = AddressFormatter.foldedLineLength - (name.utf8.count + 2) - 2 - next.address.utf8.count
        for leadLength in [fits, fits + 1] {
            let lead = Self.asciiAddress(leadLength)
            let entries: [AddressListEntry] = [.mailbox(lead), .mailbox(next)]
            let data = try Message(header: Self.header(naming: entries, in: name), parts: []).emlData()
            let lines = Self.headerLines(of: try #require(String(data: data, encoding: .utf8)))

            let expected = leadLength == fits
                ? ["\(name): \(lead.address), \(next.address)"]
                : ["\(name): \(lead.address),", " \(next.address)"]
            let start = try #require(lines.firstIndex { $0.hasPrefix("\(name): ") })
            #expect(Array(lines[start...].prefix(expected.count)) == expected)
            #expect(Self.entries(in: name, of: try Message(emlData: data).header) == entries)
        }
    }
}
