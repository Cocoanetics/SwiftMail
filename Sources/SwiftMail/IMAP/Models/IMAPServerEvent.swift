import Foundation

/// Events emitted by `IMAPServer` while an IDLE session is active.
public enum IMAPServerEvent: Sendable {
    /// New messages exist in the mailbox. Contains the current message count.
    case exists(Int)

    /// A message with the given sequence number was expunged.
    case expunge(SequenceNumber)

    /// Number of messages with the \Recent flag.
    case recent(Int)
}
