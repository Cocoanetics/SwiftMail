import NIOConcurrencyHelpers

/// Counts the LIST responses one mailbox listing receives, across every LIST command it sends.
///
/// One public `listMailboxes` call may send a LIST per namespace pattern. Each command's handler
/// draws from the same budget, so the limit bounds what the listing as a whole retains — not
/// each command on its own — and responses count before duplicates are merged.
final class ListResponseBudget: @unchecked Sendable {
    /// The most LIST responses the listing may receive; one more fails.
    let maximumCount: Int

    private var receivedCount = 0
    private let lock = NIOLock()

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    /// Counts one incoming LIST response, throwing if it goes past ``maximumCount``.
    func consume() throws {
        try lock.withLock {
            receivedCount += 1
            if receivedCount > maximumCount {
                throw ExceededListResponseLimitError(receivedCount: receivedCount, maximumCount: maximumCount)
            }
        }
    }
}
