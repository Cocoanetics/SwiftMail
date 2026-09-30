// AddressRoundTripTests.swift
// Structured addresses survive the round trip through their string form, in both the
// header and the display form, and no formatted address can carry a control character
// into a header field. Values are generated from a fixed seed, so a failure reproduces.

import Foundation
import Testing
@testable import SwiftMail

@Suite("Address round trips", .timeLimit(.minutes(1)))
struct AddressRoundTripTests {

    @Test("A mailbox reads back from its header and display forms")
    func mailboxRoundTrip() {
        var generator = AddressGenerator(seed: 0xADD2E55)
        for _ in 0..<3000 {
            let address = generator.mailbox()
            #expect(EmailAddress(address.description) == address,
                    "header form: \(address.description.debugDescription)")
            #expect(AddressParser.parseMailbox(address.displayString) == address,
                    "display form: \(address.displayString.debugDescription)")
            #expect(Self.isHeaderSafe(address.description), "\(address.description.debugDescription)")
            #expect(Self.isHeaderSafe(address.displayString), "\(address.displayString.debugDescription)")
        }
    }

    @Test("A group reads back from its header and display forms")
    func groupRoundTrip() {
        var generator = AddressGenerator(seed: 0x6E0B)
        for _ in 0..<1000 {
            let group = generator.group()
            let display = AddressFormatter.string(for: group, form: .display)
            #expect(AddressListEntry(group.description) == group, "header form: \(group.description.debugDescription)")
            #expect(AddressParser.parseAddressList(display) == [group], "display form: \(display.debugDescription)")
            #expect(Self.isHeaderSafe(group.description), "\(group.description.debugDescription)")
        }
    }

    @Test("An address list reads back from its entries joined by commas")
    func listRoundTrip() {
        var generator = AddressGenerator(seed: 0x11575)
        for _ in 0..<500 {
            let entries = (0..<generator.int(in: 0...5)).map { _ in
                generator.coin() ? AddressListEntry.mailbox(generator.mailbox()) : generator.group()
            }
            let text = entries.map(\.description).joined(separator: ", ")
            #expect(AddressParser.parseAddressList(text) == entries, "\(text.debugDescription)")
        }
    }

    @Test("Whatever text is parsed, its entries read back from their own string form")
    func arbitraryTextIsStable() {
        var generator = AddressGenerator(seed: 0xF022)
        for _ in 0..<5000 {
            Self.expectStableEntries(of: generator.syntaxSoup())
        }
    }

    @Test("Well-formed lists with a few characters inserted or removed parse stably")
    func mutatedListsAreStable() {
        var generator = AddressGenerator(seed: 0x3D17)
        for _ in 0..<3000 {
            let entries = (0..<generator.int(in: 1...4)).map { _ in
                generator.coin() ? AddressListEntry.mailbox(generator.mailbox()) : generator.group()
            }
            let text = entries.map { AddressFormatter.string(for: $0, form: generator.coin() ? .header : .display) }
                .joined(separator: ", ")
            Self.expectStableEntries(of: generator.mutated(text))
        }
    }

    /// Every entry parsed from `text`, invalid text included, is header-safe
    /// and reads back from its own header and display forms.
    private static func expectStableEntries(of text: String) {
        for entry in AddressParser.parseAddressList(text) {
            let display = AddressFormatter.string(for: entry, form: .display)
            #expect(isHeaderSafe(entry.description), "\(text.debugDescription)")
            #expect(isHeaderSafe(display), "\(text.debugDescription)")
            #expect(AddressListEntry(entry.description) == entry, "\(text.debugDescription)")
            #expect(AddressParser.parseAddressList(display) == [entry], "\(text.debugDescription)")
        }
    }

    @Test("Invalid text that would read back as something else is escaped, and reads back as itself")
    func invalidTextNeedingEscapes() {
        let texts = [
            "victim@example.com", "Bob <bob@example.com>", "Jörg [Vertrieb <joerg@example.com>", "Team: a@example.com;",
            "Doe, John", " padded ", "", "\"quoted\"", "=?UTF-8?Q?x?=", "bell\u{0007}",
            "Zoë <zoe@example.com>\r\nBcc: attacker@example.com"
        ]
        for text in texts {
            let entry = AddressListEntry.invalid(text)
            let display = AddressFormatter.string(for: entry, form: .display)
            #expect(AddressListEntry(entry.description) == entry, "header form: \(entry.description.debugDescription)")
            #expect(AddressParser.parseAddressList(display) == [entry], "display form: \(display.debugDescription)")
            #expect(Self.isHeaderSafe(entry.description), "\(entry.description.debugDescription)")
            #expect(Self.isHeaderSafe(display), "\(display.debugDescription)")
        }
        // A header gets encoded-words, which no reader takes for an address; display text is quoted.
        let victim = AddressListEntry.invalid("victim@example.com")
        #expect(victim.description == "=?UTF-8?B?dmljdGltQGV4YW1wbGUuY29t?=")
        #expect(AddressFormatter.string(for: victim, form: .display) == "\"victim@example.com\"")
        #expect(AddressFormatter.string(for: .invalid("Doe, John"), form: .display) == "\"Doe, John\"")
        // Text that reads back as itself is written as it is.
        #expect(AddressListEntry.invalid("Doe").description == "Doe")
        #expect(AddressListEntry.invalid("john@").description == "john@")
    }

    @Test("A caller-built address with a control character can't inject a header field")
    func controlsNeverReachTheHeader() {
        let hostile = [
            EmailAddress(address: "victim@example.com\r\nBcc: attacker@example.com"),
            EmailAddress(name: "Täglicher Bericht", address: "victim@example.com\r\nBcc: attacker@example.com"),
            EmailAddress(name: "Zoë", address: "victim@example.com\u{000B}Bcc: attacker@example.com"),
            EmailAddress(name: "Bob\r\nBcc: attacker@example.com", address: "bob@example.com"),
            EmailAddress(name: "Alice", address: "alice@example.com\u{0085}\u{007F}\u{0000}")
        ]
        for address in hostile {
            #expect(Self.isHeaderSafe(address.description), "\(address.description.debugDescription)")
            #expect(Self.isHeaderSafe(address.displayString), "\(address.displayString.debugDescription)")
            #expect(!address.description.contains("\nBcc"))
        }
        // An address holding a control is written as encoded-words, never with the
        // control stripped, which would name a different mailbox.
        let victim = EmailAddress(address: "victim\u{0007}@example.com")
        #expect(victim.description.hasPrefix("=?UTF-8?B?"))
        #expect(EmailAddress(victim.description) == nil)
        #expect(AddressParser.parseAddressList(victim.displayString).mailboxes.isEmpty)
        // HTAB is legal inside a quoted local-part and is kept.
        #expect(EmailAddress(address: "\"first\tlast\"@example.com").description == "\"first\tlast\"@example.com")
    }

    @Test("A caller-built malformed addr-spec can't become one or more real mailboxes")
    func malformedAddrSpecNeverBecomesMailboxes() {
        let values = [
            "victim@example.com, attacker@example.com",
            "Alice <alice@example.com>",
            " victim@example.com",
            "\"victim\"@example.com"
        ]
        for value in values {
            let address = EmailAddress(address: value)
            #expect(address.description.hasPrefix("=?UTF-8?"), "\(value)")
            #expect(AddressParser.parseAddressList(address.description) == [.invalid(value)], "\(value)")
            #expect(AddressParser.parseAddressList(address.displayString) == [.invalid(value)], "\(value)")
        }
    }

    @Test("A name that starts with U+FEFF keeps it through an encoded-word")
    func byteOrderMarkInName() {
        for name in ["\u{FEFF}John", "\u{FEFF}"] {
            let address = EmailAddress(name: name, address: "j@example.com")
            #expect(EmailAddress(address.description) == address, "\(address.description.debugDescription)")
        }
        let group = AddressListEntry.group(name: "\u{FEFF}Team", members: [])
        #expect(AddressListEntry(group.description) == group)
        #expect("=?UTF-8?B?77u/Sm9obg==?=".decodeMIMEHeader() == "\u{FEFF}John")
    }

    @Test("Decoding an address keeps an empty name as no name")
    func codableEmptyName() throws {
        let decoded = try JSONDecoder().decode(EmailAddress.self, from: Data(#"{"name":"","address":"a@b.com"}"#.utf8))
        #expect(decoded == EmailAddress(address: "a@b.com"))
        #expect(decoded.name == nil)
        let named = EmailAddress(name: "Ann", address: "a@b.com")
        #expect(try JSONDecoder().decode(EmailAddress.self, from: JSONEncoder().encode(named)) == named)
    }

    @Test("A UTF-8 addr-spec is written as address syntax, never as an encoded-word")
    func utf8AddrSpecIsNotEncoded() {
        let address = EmailAddress(name: "Alice", address: "用户@example.com")
        #expect(address.description == "Alice <用户@example.com>")
        #expect(EmailAddress(address.description) == address)
    }

    @Test("A name that address syntax can't carry bare is quoted or encoded")
    func nameQuoting() {
        #expect(EmailAddress(name: "Doe, Jane", address: "jane@example.com").description
            == "\"Doe, Jane\" <jane@example.com>")
        #expect(EmailAddress(name: " Jane ", address: "jane@example.com").description
            == "\" Jane \" <jane@example.com>")
        #expect(EmailAddress(name: "Jane  Doe", address: "jane@example.com").description
            == "\"Jane  Doe\" <jane@example.com>")
        #expect(EmailAddress(name: #"Jane "JJ" Doe"#, address: "jane@example.com").displayString
            == #""Jane \"JJ\" Doe" <jane@example.com>"#)
        #expect(EmailAddress(name: "Zoë Müller", address: "z@example.com").displayString
            == "Zoë Müller <z@example.com>")
        #expect(EmailAddress(name: "", address: "a@example.com") == EmailAddress(address: "a@example.com"))
    }

    /// Whether `text` holds no control character a header field can't carry: the
    /// only line breaks allowed are the CRLFs of folds, followed by white space.
    static func isHeaderSafe(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where AddressSyntax.isForbiddenControl(scalar) {
            let isFoldCR = scalar == "\r" && index + 2 < scalars.count
                && scalars[index + 1] == "\n" && AddressSyntax.isWSP(scalars[index + 2])
            let isFoldLF = scalar == "\n" && index > 0 && scalars[index - 1] == "\r"
                && index + 1 < scalars.count && AddressSyntax.isWSP(scalars[index + 1])
            if !isFoldCR && !isFoldLF {
                return false
            }
        }
        return true
    }
}

/// Generates addresses in the canonical form ``AddressParser`` produces, and
/// arbitrary text heavy in address syntax. SplitMix64 keeps it reproducible.
struct AddressGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    private static let namePieces = [
        "a", "Jane", "Z", "0", " ", " ", "  ", "\t", "\"", "\\", "(", ")", ",", ".", ":", ";", "<", ">", "@",
        "[", "]", "'", "_", "-", "=?UTF-8?Q?x?=", "=?", "?=", "é", "홍", "😀", "\u{0301}", "\u{00A0}",
        "\u{2003}", "\u{202E}", "\u{FEFF}", "\r", "\n", "\r\n", "\u{0000}", "\u{000B}", "\u{007F}", "\u{0085}"
    ]
    private static let atomPieces = [
        "a", "b", "Z", "0", "9", "+", "-", "_", "=", "?", "'", "{", "~", "é", "用", "\u{00A0}"
    ]
    private static let quotedPieces = ["a", " ", "\t", ".", "..", "\"", "\\", "@", ",", ":", "(", "<", "é", "用"]
    private static let literalPieces = ["1", ".", ":", " ", "<", "\"", "a", "IPv6:", "\\]", "\\a", "@"]
    private static let soupPieces = [
        "a", "b", "user", "example.com", "@", ".", ",", ";", ":", "<", ">", "(", ")", "[", "]", "\"", "\\",
        " ", "\t", "\r\n ", "\r", "\n", "=?UTF-8?Q?x?=", "=?UTF-8?B?w4Q=?=", "é", "\u{0301}", "\u{0000}",
        "Team:", "Doe, Jane", "<@relay:", "a@b"
    ]

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func coin() -> Bool {
        next() & 1 == 0
    }

    private mutating func text(from pieces: [String], count: ClosedRange<Int>) -> String {
        (0..<int(in: count)).map { _ in pieces[int(in: 0...(pieces.count - 1))] }.joined()
    }

    mutating func name() -> String {
        text(from: Self.namePieces, count: 0...8)
    }

    mutating func mailbox() -> EmailAddress {
        let localPart: String
        if coin() {
            localPart = (0..<int(in: 1...3)).map { _ in text(from: Self.atomPieces, count: 1...4) }
                .joined(separator: ".")
        } else {
            localPart = text(from: Self.quotedPieces, count: 0...6)
        }
        let domain = coin()
            ? (0..<int(in: 1...3)).map { _ in text(from: Self.atomPieces, count: 1...4) }.joined(separator: ".")
            : "[" + text(from: Self.literalPieces, count: 0...6) + "]"
        let displayName = coin() ? name() : nil
        return EmailAddress(name: displayName, address: AddressSyntax.addrSpec(localPart: localPart, domain: domain))
    }

    mutating func group() -> AddressListEntry {
        .group(name: name(), members: (0..<int(in: 0...3)).map { _ in mailbox() })
    }

    mutating func syntaxSoup() -> String {
        text(from: Self.soupPieces, count: 0...14)
    }

    /// `text` with one to three edits: a piece of address syntax inserted, or
    /// a scalar removed.
    mutating func mutated(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        for _ in 0..<int(in: 1...3) {
            let index = int(in: 0...scalars.count)
            if coin() || scalars.isEmpty {
                let piece = Self.soupPieces[int(in: 0...(Self.soupPieces.count - 1))]
                scalars.insert(contentsOf: piece.unicodeScalars, at: index)
            } else {
                scalars.remove(at: min(index, scalars.count - 1))
            }
        }
        return String(unicodeScalars: scalars)
    }
}
