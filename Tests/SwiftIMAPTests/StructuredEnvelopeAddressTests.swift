import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import SwiftMail

/// Structured envelope addresses (`fromAddress`, `toAddresses`, …), kept apart
/// from the other handler tests so each file stays within the lint limits.
extension FetchMessageInfoHandlerTests {
    // MARK: - Structured Envelope Addresses

    @Test
    func testStructuredAddressPopulatesFromAndTo() async throws {
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: "Alice Example", mailbox: "alice", host: "example.com")],
            to: [
                imapAddress(name: "Bob Example", mailbox: "bob", host: "example.com"),
                imapAddress(name: nil, mailbox: "carol", host: "example.com")
            ]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].fromAddress == EmailAddress(name: "Alice Example", address: "alice@example.com"))
        #expect(infos[0].toAddresses == [
            EmailAddress(name: "Bob Example", address: "bob@example.com"),
            EmailAddress(name: nil, address: "carol@example.com")
        ])
    }

    @Test
    func testStructuredFromAddressDecodesRFC2047DisplayName() async throws {
        // Same encoded-word ("Täglicher Bericht") used by EMLTests.testRFC2047Subject,
        // here applied to a personName instead of a Subject header.
        let encodedName = "=?UTF-8?B?VMOkZ2xpY2hlciBCZXJpY2h0?="
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: encodedName, mailbox: "alice", host: "example.com")]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].fromAddress?.name == "Täglicher Bericht")
        // The legacy string decodes the same encoded word via the same helper -
        // the structured field isn't decoding it differently.
        #expect(infos[0].from == "\"Täglicher Bericht\" <alice@example.com>")
    }

    @Test
    func testStructuredToAddressesFlattenGroupsWithoutSyntheticEntry() async throws {
        let groupAddresses = [
            imapAddress(name: nil, mailbox: "Team", host: nil), // group start
            imapAddress(name: nil, mailbox: "alice", host: "x.com"),
            imapAddress(name: nil, mailbox: "bob", host: "x.com"),
            imapAddress(name: nil, mailbox: nil, host: nil) // group end
        ]
        let envelope = envelopeWithAddresses(to: groupAddresses)

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        // Flattened to the two members - no synthetic "Team" entry.
        #expect(infos[0].toAddresses == [
            EmailAddress(name: nil, address: "alice@x.com"),
            EmailAddress(name: nil, address: "bob@x.com")
        ])
    }

    @Test
    func testStructuredAddressDropsAndNormalisesMalformedEntries() async throws {
        // IMAP represents "field absent" with NIL, distinct from "field present but
        // empty" (""). A NIL host is reserved by the wire grammar as a group
        // boundary marker, so these malformed single addresses use an empty string
        // host/mailbox rather than NIL to exercise structuredAddress's own
        // isEmpty-based branching without being reinterpreted as a group.
        let ccAddresses = [
            imapAddress(name: nil, mailbox: "devnull", host: ""), // mailbox, no host
            imapAddress(name: nil, mailbox: "", host: "example.com"), // host, no mailbox
            imapAddress(name: nil, mailbox: "", host: "") // neither - dropped
        ]
        let envelope = envelopeWithAddresses(cc: ccAddresses)

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].ccAddresses == [
            EmailAddress(name: nil, address: "devnull"),
            EmailAddress(name: nil, address: "@example.com")
        ])
    }

    @Test
    func testLegacyFromAndToStringsAreUnchangedByStructuredAddresses() async throws {
        // formatAddress (which produces from/to/cc/bcc) is untouched by the
        // structured-address addition - this pins its exact output so the new
        // fields can be seen to be additive, not a replacement.
        let envelope = envelopeWithAddresses(
            from: [imapAddress(name: "Alice Example", mailbox: "alice", host: "example.com")],
            to: [
                imapAddress(name: nil, mailbox: "bob", host: "example.com"),
                imapAddress(name: nil, mailbox: "Team", host: nil), // group start
                imapAddress(name: nil, mailbox: "carol", host: "example.com"),
                imapAddress(name: nil, mailbox: nil, host: nil) // group end
            ]
        )

        let infos = try await executeFetch(
            [
                fetchResponse(sequenceNumber: 1, envelope: envelope, headerBlock: "\r\n"),
                "A001 OK FETCH completed\r\n"
            ]
        )

        #expect(infos.count == 1)
        #expect(infos[0].from == "\"Alice Example\" <alice@example.com>")
        #expect(infos[0].to == ["bob@example.com", "Team: carol@example.com"])
    }

    /// Build a `Date` from explicit Y/M/D + H/M/S components, anchored to UTC.
    /// Folded into a single `DateComponents` parameter so the helper signature
    /// stays under the 6-parameter swiftlint limit while keeping call sites
    /// readable via the labelled `DateComponents` initializer.

    private func envelopeWithAddresses(
        subject: String = "Test",
        from: [String] = [],
        to: [String] = [],
        cc: [String] = [],
        bcc: [String] = [],
        messageId: String = "<msg@example.com>"
    ) -> String {
        let recipients = "\(addressList(to)) \(addressList(cc)) \(addressList(bcc))"
        return "(NIL \"\(subject)\" \(addressList(from)) NIL NIL \(recipients) NIL \"\(messageId)\")"
    }

    /// Render an IMAP addr-list: `NIL` when empty, else the addresses concatenated
    /// with no separator (matching how a real server encodes ENVELOPE addresses).
    private func addressList(_ addresses: [String]) -> String {
        addresses.isEmpty ? "NIL" : "(\(addresses.joined()))"
    }

    /// Render a single IMAP `address` structure: `(name adl mailbox host)`.
    ///
    /// `nil` renders as `NIL` (field absent); a non-nil `String` (including `""`)
    /// renders as a quoted string (field present, possibly empty). This distinction
    /// matters because the wire grammar treats a `NIL` host as a group start/end
    /// marker, so malformed-but-present addresses must use `""`, not `nil`, to be
    /// parsed as ordinary single addresses rather than group boundaries.
    private func imapAddress(name: String?, mailbox: String?, host: String?) -> String {
        let nameField = name.map { "\"\($0)\"" } ?? "NIL"
        let mailboxField = mailbox.map { "\"\($0)\"" } ?? "NIL"
        let hostField = host.map { "\"\($0)\"" } ?? "NIL"
        return "(\(nameField) NIL \(mailboxField) \(hostField))"
    }
}
