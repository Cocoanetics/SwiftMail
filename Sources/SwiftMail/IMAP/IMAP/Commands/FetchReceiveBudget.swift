import NIOConcurrencyHelpers

/// Counts what one metadata FETCH call receives, across every FETCH command it sends.
///
/// A streaming call sends one command per chunk. Each command's handler draws from the same
/// budget, so ``FetchReceiveLimits`` bound the call as a whole, not each chunk on its own.
final class FetchReceiveBudget: @unchecked Sendable {
    private let maximumReplies: UInt64?
    private let maximumPayloadBytes: UInt64?

    private var receivedReplies: UInt64 = 0
    private var receivedPayloadBytes: UInt64 = 0
    private let lock = NIOLock()

    private init(maximumReplies: UInt64?, maximumPayloadBytes: UInt64?) {
        self.maximumReplies = maximumReplies
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// The budget for one call, or `nil` when `limits` bound nothing.
    /// - Throws: `IMAPError.invalidArgument` for a negative ``FetchReceiveLimits/maximumReplies``.
    static func make(for limits: FetchReceiveLimits) throws -> FetchReceiveBudget? {
        var maximumReplies: UInt64?
        if let replies = limits.maximumReplies {
            guard let replies = UInt64(exactly: replies) else {
                throw IMAPError.invalidArgument("maximumReplies must not be negative")
            }
            maximumReplies = replies
        }
        guard maximumReplies != nil || limits.maximumPayloadBytes != nil else { return nil }
        return FetchReceiveBudget(maximumReplies: maximumReplies, maximumPayloadBytes: limits.maximumPayloadBytes)
    }

    /// Counts one FETCH reply, throwing if it goes past the reply limit.
    func consumeReply() throws {
        try lock.withLock {
            receivedReplies = try Self.add(1, to: receivedReplies, limit: maximumReplies, dimension: .replies)
        }
    }

    /// Counts a streamed section by its declared size, throwing if it goes past the payload limit.
    func consumePayload(declaredByteCount: Int) throws {
        let byteCount = UInt64(max(0, declaredByteCount))
        try lock.withLock {
            receivedPayloadBytes = try Self.add(
                byteCount, to: receivedPayloadBytes, limit: maximumPayloadBytes, dimension: .payloadBytes
            )
        }
    }

    private static func add(
        _ amount: UInt64,
        to used: UInt64,
        limit: UInt64?,
        dimension: FetchReceiveLimitExceededError.Dimension
    ) throws -> UInt64 {
        let (sum, overflow) = used.addingReportingOverflow(amount)
        guard let limit else { return overflow ? .max : sum }
        let attempted = overflow ? UInt64.max : sum
        guard !overflow, sum <= limit else {
            throw FetchReceiveLimitExceededError(dimension: dimension, limit: limit, attemptedUsage: attempted)
        }
        return sum
    }
}
