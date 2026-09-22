extension Mailbox {
    /// The result of a QRESYNC mailbox selection.
    public struct ResyncSelection: Sendable {
        /// Metadata for the selected mailbox through successful command completion.
        /// The message count already accounts for live deletions and EXISTS responses
        /// in arrival order; do not subtract either deletion set from it.
        public let selection: Mailbox.Selection

        /// UIDs the server reports as having vanished before this resynchronization.
        /// These historical deletions do not reduce the returned message count.
        public let vanishedEarlier: UIDSet

        /// UIDs reported by plain VANISHED for the selected mailbox during this command.
        /// These live deletions are already reflected in the returned message count.
        public let vanished: UIDSet

        /// Complete replacement flag arrays, keyed by message UID.
        /// Results returned by selection exclude UIDs in either deletion set.
        public let changedFlags: [UID: [Flag]]

        /// Creates a mailbox resynchronization result.
        ///
        /// - Parameters:
        ///   - selection: Metadata for the selected mailbox, including its current message count.
        ///   - vanishedEarlier: Historical deletions reported by VANISHED (EARLIER).
        ///   - changedFlags: Complete replacement flag arrays for surviving messages, keyed by UID.
        ///   - vanished: Live deletions reported by plain VANISHED during selection. Defaults to an empty set.
        public init(
            selection: Mailbox.Selection,
            vanishedEarlier: UIDSet,
            changedFlags: [UID: [Flag]],
            vanished: UIDSet = UIDSet()
        ) {
            self.selection = selection
            self.vanishedEarlier = vanishedEarlier
            self.changedFlags = changedFlags
            self.vanished = vanished
        }
    }
}
