extension Mailbox {
    /// The result of a QRESYNC mailbox selection.
    public struct ResyncSelection: Sendable {
        /// Ordinary metadata reported while selecting the mailbox.
        public let selection: Mailbox.Selection

        /// UIDs the server reports as having vanished before this resynchronization.
        public let vanishedEarlier: UIDSet

        /// Complete replacement flag arrays, keyed by message UID.
        public let changedFlags: [UID: [Flag]]

        /// Creates a mailbox resynchronization result.
        public init(
            selection: Mailbox.Selection,
            vanishedEarlier: UIDSet,
            changedFlags: [UID: [Flag]]
        ) {
            self.selection = selection
            self.vanishedEarlier = vanishedEarlier
            self.changedFlags = changedFlags
        }
    }
}
