import Foundation

/// The flags of one message whose modification sequence moved past a known value (RFC 7162 CONDSTORE).
///
/// Returned by `IMAPServer.fetchFlagsChangedSince(_:modificationSequence:)`.
/// `flags` is the message's complete current flag set, not a delta; replace any stored flags with it.
public struct ChangedMessageFlags: Sendable, Equatable {
    /// The message's UID in the selected mailbox.
    public let uid: UID

    /// The complete current flag set of the message.
    public let flags: [Flag]

    /// The message's current modification sequence (the `MODSEQ` FETCH data item).
    public let modificationSequence: UInt64

    /// Creates a changed-flags record.
    /// - Parameters:
    ///   - uid: The message's UID in the selected mailbox.
    ///   - flags: The complete current flag set of the message.
    ///   - modificationSequence: The message's current modification sequence.
    public init(uid: UID, flags: [Flag], modificationSequence: UInt64) {
        self.uid = uid
        self.flags = flags
        self.modificationSequence = modificationSequence
    }
}
