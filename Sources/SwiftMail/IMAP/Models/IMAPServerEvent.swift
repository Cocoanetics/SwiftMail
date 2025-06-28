import Foundation

/// Events emitted by `IMAPServer` while an IDLE session is active.
public enum IMAPServerEvent: Sendable {
    /// New messages exist in the mailbox. Contains the current message count.
    case exists(Int)

    /// A message with the given sequence number was expunged.
    case expunge(SequenceNumber)

    /// Number of messages with the \Recent flag.
    case recent(Int)

    /// A message has updated attributes.
    case fetch(SequenceNumber, [IMAPMessageAttribute])

    /// An alert from the server.
    case alert(String)

    /// Updated capabilities announced by the server.
    case capability([String])

    /// The server is closing the connection.
    case bye(String?)
}
