import Foundation

/// Events produced while the server is in IDLE mode.
public enum IMAPServerEvent: Sendable {
    /// A new message arrived, reported by UID.
    case newMessage(UID)

    /// Message with the given sequence number was expunged.
    case expunge(SequenceNumber)

    /// The flags of a message changed.
    case flagsChanged(SequenceNumber, [Flag])

    /// The server is closing the connection.
    case bye(String)
}
