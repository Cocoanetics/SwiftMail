// AddressListFoldingTests.swift
// Address-list header fields are folded between addresses, so a long list
// never adds up past RFC 5322's 998-octet line limit (§2.1.1). An address is
// never split: only one that long by itself passes the limit.

import Foundation
import Testing
@testable import SwiftMail

@Suite("Address-list folding", .timeLimit(.minutes(1)))
struct AddressListFoldingTests {
    /// RFC 5322 §2.1.1: a line MUST be no more than 998 octets, excluding the CRLF.
    static let lineLimit = 998

    /// `count` named addresses of about 50 octets each, so 40 of them make an
    /// unfolded field of about 2,000 octets.
    static func addresses(_ count: Int, prefix: String) -> [EmailAddress] {
        (0..<count).map {
            EmailAddress(name: "Recipient \(prefix) \($0)", address: "recipient.\(prefix).\($0)@example.com")
        }
    }

    static func longListEmail() -> Email {
        Email(
            sender: EmailAddress(name: "Sender", address: "sender@example.com"),
            recipients: addresses(40, prefix: "to"),
            ccRecipients: addresses(40, prefix: "cc"),
            bccRecipients: addresses(40, prefix: "bcc"),
            subject: "Team mail",
            textBody: "body"
        )
    }

    /// The header block of `content`, one line per element, each without its CRLF.
    static func headerLines(of content: String) -> [String] {
        let header = content.components(separatedBy: "\r\n\r\n")[0]
        return header.components(separatedBy: "\r\n")
    }

    /// `text` unfolded (RFC 5322 §2.2.3): each CRLF followed by white space is removed.
    static func unfold(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n ", with: " ", options: .literal)
            .replacingOccurrences(of: "\r\n\t", with: "\t", options: .literal)
    }

    /// An address list as a field body reads once unfolded: the addresses'
    /// own text, which may hold folds, joined by commas.
    static func unfoldedList(_ addresses: [String]) -> String {
        unfold(addresses.joined(separator: ", "))
    }

    /// Every field in the header block of `content`, unfolded, as name and body.
    static func unfoldedFields(of content: String) -> [(name: String, body: String)] {
        let header = content.components(separatedBy: "\r\n\r\n")[0]
        return unfold(header).components(separatedBy: "\r\n").map { line in
            let colon = line.firstIndex(of: ":") ?? line.endIndex
            let body = line[colon...].dropFirst().drop(while: { $0 == " " })
            return (String(line[..<colon]), String(body))
        }
    }

    static func body(of name: String, in content: String) -> [String] {
        unfoldedFields(of: content).filter { $0.name == name }.map(\.body)
    }

    @Test("Every header line of a long To, Cc and Bcc list stays within 78 octets")
    func longListsAreFoldedBetweenAddresses() throws {
        let email = Self.longListEmail()
        let content = email.constructContent(includeBccHeader: true)
        let lines = Self.headerLines(of: content)

        let longest = lines.map(\.utf8.count).max() ?? 0
        #expect(longest <= AddressFormatter.foldedLineLength)
        #expect(longest <= Self.lineLimit)

        // Unfolded, each field is exactly the list it names, written once.
        let fields: [(String, [EmailAddress])] = [
            ("To", email.recipients), ("Cc", email.ccRecipients), ("Bcc", email.bccRecipients)
        ]
        for (name, addresses) in fields {
            #expect(Self.body(of: name, in: content) == [Self.unfoldedList(addresses.map { $0.headerString() })])
        }
        // Folding starts no field of its own: the fields are those of a
        // one-recipient message.
        let single = Email(
            sender: email.sender, recipients: [email.recipients[0]], ccRecipients: [email.ccRecipients[0]],
            bccRecipients: [email.bccRecipients[0]], subject: email.subject, textBody: email.textBody)
        #expect(Self.unfoldedFields(of: content).map(\.name)
            == Self.unfoldedFields(of: single.constructContent(includeBccHeader: true)).map(\.name))
    }

    @Test("The folded fields pass the header check of an SMTP send and of a kept copy")
    func foldedFieldsPassTheHeaderCheck() throws {
        let email = Self.longListEmail()

        try SMTPServer.checkHeaderFields(email.preparedContent().headerFields)
        let keptCopy = try email.keptCopyContent(use8BitMIME: false)

        #expect(Self.headerLines(of: keptCopy).allSatisfy { $0.utf8.count <= AddressFormatter.foldedLineLength })
    }

    @Test("A short list stays on one line, as before")
    func shortListIsUnchanged() {
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: [EmailAddress(address: "a@example.com"), EmailAddress(name: "Bee", address: "b@example.com")],
            subject: "Hi",
            textBody: "body"
        )
        let lines = Self.headerLines(of: email.constructContent())

        #expect(lines.contains("To: a@example.com, Bee <b@example.com>"))
    }

    @Test("An address longer than a line is never split, and the others still fold around it")
    func overlongAddressStaysWhole() {
        let longName = Array(repeating: "Longname", count: 15).joined(separator: " ")
        let long = EmailAddress(name: longName, address: "long@example.com")
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: Self.addresses(3, prefix: "a") + [long] + Self.addresses(30, prefix: "b"),
            subject: "Hi",
            textBody: "body"
        )
        let content = email.constructContent()
        let lines = Self.headerLines(of: content)

        #expect(lines.allSatisfy { $0.utf8.count <= Self.lineLimit })
        #expect(lines.filter { $0.utf8.count > AddressFormatter.foldedLineLength } == [" \(long.headerString()),"])
        let unfolded = Self.unfoldedList(email.recipients.map { $0.headerString() })
        #expect(Self.body(of: "To", in: content) == [unfolded])
    }

    @Test("Long encoded display names keep their own folds, and the list reads back the same")
    func encodedNamesFoldAndRoundTrip() throws {
        let names = (0..<30).map { "\(String(repeating: "한", count: 30)) \($0)" }
        let recipients = names.enumerated().map { EmailAddress(name: $1, address: "member\($0)@example.com") }
        let email = Email(
            sender: EmailAddress(address: "sender@example.com"),
            recipients: recipients,
            subject: "Hi",
            textBody: "body"
        )
        let content = email.constructContent()

        #expect(Self.headerLines(of: content).allSatisfy { $0.utf8.count <= Self.lineLimit })
        #expect(Self.body(of: "To", in: content) == [Self.unfoldedList(recipients.map { $0.headerString() })])

        let restored = try Email(message: Message(emlData: Data(content.utf8)))
        #expect(restored.recipients == recipients)
    }

    @Test("A long list written to EML is folded and parses back to the same addresses")
    func emlListsAreFoldedAndRoundTrip() throws {
        let email = Self.longListEmail()
        let data = try Message(email: email).emlData()
        let content = try #require(String(data: data, encoding: .utf8))

        #expect(Self.headerLines(of: content).allSatisfy { $0.utf8.count <= AddressFormatter.foldedLineLength })

        let restored = try Email(message: Message(emlData: data))
        #expect(restored.recipients == email.recipients)
        #expect(restored.ccRecipients == email.ccRecipients)
        #expect(restored.bccRecipients == email.bccRecipients)
    }

    @Test("A long group written to EML is folded between its members")
    func emlGroupIsFoldedBetweenMembers() throws {
        let members = Self.addresses(40, prefix: "team")
        var header = MessageInfo(sequenceNumber: SequenceNumber(0), from: "sender@example.com")
        header.toAddresses = [.group(name: "Team", members: members), .mailbox(EmailAddress(address: "z@example.com"))]
        header.ccAddresses = [.group(name: "Nobody", members: [])]
        let data = try Message(header: header, parts: []).emlData()
        let content = try #require(String(data: data, encoding: .utf8))

        #expect(Self.headerLines(of: content).allSatisfy { $0.utf8.count <= AddressFormatter.foldedLineLength })
        #expect(Self.body(of: "To", in: content) == [Self.unfoldedList(header.toAddresses.map(\.description))])
        #expect(Self.body(of: "Cc", in: content) == ["Nobody:;"])

        let parsed = try Message(emlData: data)
        #expect(parsed.header.toAddresses == header.toAddresses)
        #expect(parsed.header.ccAddresses == header.ccAddresses)
    }

    @Test("Pieces are joined by commas and folded only before a piece that would pass the line")
    func foldsOnlyWhereALineWouldPassTheLength() {
        let width = AddressFormatter.foldedLineLength
        // "To: " plus a 70-octet piece and its comma leaves no room for a
        // 10-octet piece, which goes on the next line.
        let first = String(repeating: "a", count: 70)
        let short = String(repeating: "b", count: 10)
        #expect(AddressFormatter.foldedList([first, short], fieldName: "To") == "\(first),\r\n \(short)")

        // A piece that fits exactly is kept on the line: 4 + 61 + 1 + 1 + 11 = 78.
        let fits = String(repeating: "c", count: 61)
        let exact = String(repeating: "d", count: 11)
        #expect(4 + fits.utf8.count + 2 + exact.utf8.count == width)
        #expect(AddressFormatter.foldedList([fits, exact], fieldName: "To") == "\(fits), \(exact)")

        // A piece with its own fold is judged on its first line, and the next
        // piece counts from its last.
        let folded = "\(String(repeating: "e", count: 10))\r\n \(String(repeating: "f", count: 100))"
        let tail = "\(String(repeating: "g", count: 70))\r\n \(String(repeating: "h", count: 10))"
        #expect(AddressFormatter.foldedList(["x", folded, tail, short], fieldName: "To")
            == "x, \(folded),\r\n \(tail), \(short)")

        #expect(AddressFormatter.foldedList([], fieldName: "To").isEmpty)
        #expect(AddressFormatter.foldedList([first], fieldName: "To") == first)
    }

    static func fill(_ letter: Character, _ count: Int) -> String {
        String(repeating: letter, count: count)
    }

    /// A list whose last piece can end its line at exactly 78 octets.
    struct FoldBoundary: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let fieldName: String
        /// The pieces before the last one.
        let lead: [String]
        /// `lead` as written, up to the comma before the last piece.
        let writtenLead: String
        /// The length of a last piece that ends its line at exactly 78 octets.
        let lastThatFits: Int
    }

    static let foldBoundaries: [FoldBoundary] = {
        let a61 = Self.fill("a", 61), a30 = Self.fill("a", 30), b30 = Self.fill("b", 30)
        let a70 = Self.fill("a", 70), b40 = Self.fill("b", 40), a60 = Self.fill("a", 60)
        // Its first line ends the field's first line at 78 octets, after "To: x, ".
        let innerFolds = "\(Self.fill("i", 71))\r\n \(Self.fill("j", 20))\r\n \(Self.fill("k", 30))"
        return [
            FoldBoundary(testDescription: "on the first line", fieldName: "To",
                         lead: [a61], writtenLead: "\(a61),", lastThatFits: 11),
            FoldBoundary(testDescription: "after a piece that fit", fieldName: "To",
                         lead: [a30, b30], writtenLead: "\(a30), \(b30),", lastThatFits: 10),
            FoldBoundary(testDescription: "after a fold", fieldName: "To",
                         lead: [a70, b40], writtenLead: "\(a70),\r\n \(b40),", lastThatFits: 35),
            FoldBoundary(testDescription: "after a piece with folds of its own", fieldName: "To",
                         lead: ["x", innerFolds], writtenLead: "x, \(innerFolds),", lastThatFits: 45),
            FoldBoundary(testDescription: "after a longer field name", fieldName: "Bcc",
                         lead: [a60], writtenLead: "\(a60),", lastThatFits: 11)
        ]
    }()

    @Test("A piece that ends its line at exactly 78 octets stays on it, and one octet more folds",
          arguments: Self.foldBoundaries)
    func foldBoundaryIsTwoSided(_ boundary: FoldBoundary) {
        let fits = Self.fill("z", boundary.lastThatFits)
        let passes = fits + "z"
        let kept = AddressFormatter.foldedList(boundary.lead + [fits], fieldName: boundary.fieldName)
        #expect(kept == "\(boundary.writtenLead) \(fits)")
        let lastLine = "\(boundary.fieldName): \(kept)".components(separatedBy: "\r\n").last ?? ""
        #expect(lastLine.utf8.count == AddressFormatter.foldedLineLength)
        #expect(AddressFormatter.foldedList(boundary.lead + [passes], fieldName: boundary.fieldName)
            == "\(boundary.writtenLead)\r\n \(passes)")
    }

    @Test("Both writers count the field name toward the first line", arguments: ["To", "Cc", "Bcc"])
    func writersCountTheFieldName(_ name: String) throws {
        let next = EmailAddress(address: "b@example.com")
        // "<name>: " + lead + ", " + next is 78 octets when lead is `fits` long.
        let fits = AddressFormatter.foldedLineLength - (name.utf8.count + 2) - 2 - next.address.utf8.count
        for leadLength in [fits, fits + 1] {
            let local = Self.fill("a", leadLength - "@example.com".utf8.count)
            let lead = EmailAddress(address: local + "@example.com")
            let list = [lead, next]
            let email = Email(
                sender: EmailAddress(address: "sender@example.com"),
                recipients: name == "To" ? list : [EmailAddress(address: "to@example.com")],
                ccRecipients: name == "Cc" ? list : [],
                bccRecipients: name == "Bcc" ? list : [],
                subject: "Hi",
                textBody: "body"
            )
            let expected = leadLength == fits
                ? ["\(name): \(lead.address), \(next.address)"]
                : ["\(name): \(lead.address),", " \(next.address)"]
            let sent = Self.headerLines(of: email.constructContent(includeBccHeader: true))
            let data = try Message(email: email).emlData()
            let eml = try #require(String(data: data, encoding: .utf8))
            for lines in [sent, Self.headerLines(of: eml)] {
                let start = try #require(lines.firstIndex { $0.hasPrefix("\(name): ") })
                #expect(Array(lines[start...].prefix(expected.count)) == expected)
            }
        }
    }

    @Test("A group's pieces split it between members and join back to its text")
    func groupPiecesJoinToTheGroupText() {
        let ann = EmailAddress(name: "Ann", address: "ann@example.com")
        let bob = EmailAddress(address: "bob@example.com")
        let cases: [(AddressListEntry, [String])] = [
            (.mailbox(ann), ["Ann <ann@example.com>"]),
            (.group(name: "Team", members: [ann, bob]), ["Team: Ann <ann@example.com>", "bob@example.com;"]),
            (.group(name: "One", members: [ann]), ["One: Ann <ann@example.com>;"]),
            (.group(name: "undisclosed-recipients", members: []), ["undisclosed-recipients:;"]),
            (.invalid("not an address"), ["not an address"])
        ]
        for (entry, pieces) in cases {
            #expect(AddressFormatter.listPieces(for: entry, form: .header) == pieces)
            #expect(entry.description == pieces.joined(separator: ", "))
        }
    }
}
