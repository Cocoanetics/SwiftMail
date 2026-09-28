import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SendDraftTests {

    private static func draft(
        from: String? = "me@example.com", to: [String] = [], cc: [String] = [], bcc: [String] = []
    ) -> MessageInfo {
        MessageInfo(sequenceNumber: SequenceNumber(1), from: from, to: to, cc: cc, bcc: bcc)
    }

    private static func recipients(_ info: MessageInfo) throws -> [EmailAddress] {
        try IMAPServer.sendDraftAddresses(from: info).recipients
    }

    // MARK: - Single addresses

    @Test
    func testPlainAddress() throws {
        #expect(try Self.recipients(Self.draft(to: ["user@example.com"]))
            == [EmailAddress(address: "user@example.com")])
    }

    @Test
    func testDisplayName() throws {
        #expect(try Self.recipients(Self.draft(to: ["John Doe <john@example.com>"]))
            == [EmailAddress(name: "John Doe", address: "john@example.com")])
    }

    @Test
    func testQuotedDisplayNameWithComma() throws {
        #expect(try Self.recipients(Self.draft(to: ["\"Doe, John\" <john@example.com>"]))
            == [EmailAddress(name: "Doe, John", address: "john@example.com")])
    }

    @Test
    func testAngleBracketsOnlyAndWhitespace() throws {
        #expect(try Self.recipients(Self.draft(to: ["<noreply@example.com>"], cc: ["  user@example.com  "]))
            == [EmailAddress(address: "noreply@example.com"), EmailAddress(address: "user@example.com")])
    }

    @Test
    func testSenderIsTheFirstMailboxOfFrom() throws {
        let info = Self.draft(from: "Alice <alice@example.com>, Bob <bob@example.com>", to: ["x@example.com"])
        #expect(try IMAPServer.sendDraftAddresses(from: info).sender
            == EmailAddress(name: "Alice", address: "alice@example.com"))
    }

    // MARK: - Groups

    @Test
    func testGroupMembersAreRecipients() throws {
        #expect(try Self.recipients(Self.draft(to: ["Team: alice@example.com, bob@example.com;"])).map(\.address)
            == ["alice@example.com", "bob@example.com"])
    }

    @Test
    func testGroupWithNamedMembers() throws {
        let info = Self.draft(to: ["Friends: Alice <alice@example.com>, \"Doe, Bob\" <bob@example.com>;"])
        #expect(try Self.recipients(info) == [
            EmailAddress(name: "Alice", address: "alice@example.com"),
            EmailAddress(name: "Doe, Bob", address: "bob@example.com")
        ])
    }

    @Test
    func testEmptyGroupAddsNoRecipient() throws {
        let info = Self.draft(to: ["Undisclosed recipients:;"], bcc: ["hidden@example.com"])
        #expect(try Self.recipients(info) == [EmailAddress(address: "hidden@example.com")])
    }

    @Test
    func testGroupMixedMembers() throws {
        let info = Self.draft(to: ["Sales: plain@example.com, Named <named@example.com>, <brackets@example.com>;"])
        #expect(try Self.recipients(info).map(\.address)
            == ["plain@example.com", "named@example.com", "brackets@example.com"])
    }

    // MARK: - Rejected drafts

    @Test
    func testInvalidRecipientRejectsTheDraft() {
        let info = Self.draft(to: ["alice@example.com", "Bob <bob@example.com> carol@example.com"])
        #expect(throws: IMAPError.self) {
            try IMAPServer.sendDraftAddresses(from: info)
        }
    }

    @Test
    func testMissingOrUnusableAddressesRejectTheDraft() {
        let unusable = [
            Self.draft(from: nil, to: ["a@example.com"]),
            Self.draft(from: "junk", to: ["a@example.com"]),
            Self.draft(),
            Self.draft(to: ["Nobody:;"])
        ]
        for info in unusable {
            #expect(throws: IMAPError.self) { try IMAPServer.sendDraftAddresses(from: info) }
        }
    }
}
