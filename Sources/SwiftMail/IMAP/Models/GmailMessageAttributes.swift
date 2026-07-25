import Foundation

/// Gmail-native attributes for a message, exposed via the `X-GM-EXT-1` IMAP capability.
///
/// Gmail's IMAP extension reports a message ID and thread ID that are stable across
/// mailbox moves (unlike UIDs, which are only stable within a single mailbox), plus the
/// set of Gmail labels applied to the message. See
/// `IMAPServer.fetchGmailAttributes(for:)`.
public struct GmailMessageAttributes: Sendable, Hashable {
    /// Gmail's persistent message ID (`X-GM-MSGID`), stable across mailboxes.
    public let messageID: UInt64

    /// Gmail's persistent thread ID (`X-GM-THRID`), shared by every message in a thread.
    public let threadID: UInt64

    /// The Gmail labels applied to the message (`X-GM-LABELS`), including system labels
    /// such as `\Inbox` and `\Important` alongside user-defined labels.
    public let labels: [String]

    /// Initialize a new set of Gmail message attributes.
    /// - Parameters:
    ///   - messageID: Gmail's persistent message ID.
    ///   - threadID: Gmail's persistent thread ID.
    ///   - labels: The Gmail labels applied to the message.
    public init(messageID: UInt64, threadID: UInt64, labels: [String]) {
        self.messageID = messageID
        self.threadID = threadID
        self.labels = labels
    }
}
