import Foundation
import NIOIMAPCore

/// Events emitted by `IMAPServer` while an IDLE session is active.
public enum IMAPServerEvent: Sendable {
    /// New messages exist in the mailbox. Contains the current message count.
    case exists(Int)

    /// A message with the given sequence number was expunged.
    case expunge(SequenceNumber)

    /// RFC 7162 CONDSTORE/QRESYNC: one or more messages identified by UID have been
    /// permanently removed from the mailbox. Servers that advertise CONDSTORE or QRESYNC
    /// send this instead of (or in addition to) individual `expunge` events.
    case vanished(UIDSet)

    /// Number of messages with the \Recent flag.
    case recent(Int)

    /// The set of flags defined for the mailbox has changed.
    case flags([Flag])

    /// A message has updated attributes (identified by sequence number).
    case fetch(SequenceNumber, [MessageAttribute])

    /// A message has updated attributes (identified by UID).
    /// Emitted for UID-based FETCH responses, e.g. during QRESYNC.
    case fetchUID(UID, [MessageAttribute])

    /// An alert from the server.
    case alert(String)

    /// Updated capabilities announced by the server.
    case capability([String])

    /// The server is closing the connection.
    case bye(String?)
}
