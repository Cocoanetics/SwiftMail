import Foundation
import NIOIMAPCore

extension Mailbox {
/// Status information for a mailbox returned by the IMAP `STATUS` command.
/// A lightweight probe that doesn't select the mailbox.
public struct Status: Codable, Sendable {
    /// Number of messages in the mailbox.
    public var messageCount: Int?

    /// Number of messages marked as recent.
    public var recentCount: Int?

    /// Number of messages without the `\Seen` flag.
    public var unseenCount: Int?

    /// Next UID value expected for newly appended messages.
    public var uidNext: UID?

    /// UID validity value for the mailbox.
    public var uidValidity: UIDValidity?

    /// Total mailbox size in octets when supported by the server.
    public var size: Int?

    /// Highest modification sequence value when CONDSTORE is supported.
    public var highestModSequence: Int?

    /// Creates a new mailbox status value.
    public init(
        messageCount: Int? = nil,
        recentCount: Int? = nil,
        unseenCount: Int? = nil,
        uidNext: UID? = nil,
        uidValidity: UIDValidity? = nil,
        size: Int? = nil,
        highestModSequence: Int? = nil
    ) {
        self.messageCount = messageCount
        self.recentCount = recentCount
        self.unseenCount = unseenCount
        self.uidNext = uidNext
        self.uidValidity = uidValidity
        self.size = size
        self.highestModSequence = highestModSequence
    }

    /// Creates from NIOIMAPCore representation.
    internal init(nio: NIOIMAPCore.MailboxStatus) {
        self.messageCount = nio.messageCount
        self.recentCount = nio.recentCount
        self.unseenCount = nio.unseenCount
        self.uidNext = nio.nextUID.map { UID(nio: $0) }
        self.uidValidity = nio.uidValidity.map { UIDValidity(nio: $0) }
        self.size = nio.size
        self.highestModSequence = nio.highestModificationSequence.flatMap { Int(exactly: Int64($0)) }
    }
}
}
