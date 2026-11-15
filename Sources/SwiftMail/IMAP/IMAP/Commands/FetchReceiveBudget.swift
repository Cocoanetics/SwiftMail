import NIOConcurrencyHelpers

/// Counts what one metadata FETCH call receives, across every FETCH command (chunk) it sends.
final class FetchReceiveBudget: @unchecked Sendable {
    private let maximumReplies: UInt64?
    private let maximumPayloadBytes: UInt64?
    private var replies: UInt64 = 0
    private var payloadBytes: UInt64 = 0
    private let lock = NIOLock()

    private init(maximumReplies: UInt64?, maximumPayloadBytes: UInt64?) {
        self.maximumReplies = maximumReplies
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    /// The budget for one call, or `nil` when `limits` bound nothing.
    static func make(for limits: FetchReceiveLimits) throws -> FetchReceiveBudget? {
        let maximumReplies = try limits.maximumReplies.map { replies -> UInt64 in
            guard let replies = UInt64(exactly: replies) else {
                throw IMAPError.invalidArgument("maximumReplies must not be negative")
            }
            return replies
        }
        guard maximumReplies != nil || limits.maximumPayloadBytes != nil else { return nil }
        return FetchReceiveBudget(maximumReplies: maximumReplies, maximumPayloadBytes: limits.maximumPayloadBytes)
    }

    func consumeReply() throws {
        try lock.withLock { try Self.add(1, to: &replies, limit: maximumReplies, .replies) }
    }

    func consumePayload(declaredByteCount: Int) throws {
        let byteCount = UInt64(max(0, declaredByteCount))
        try lock.withLock { try Self.add(byteCount, to: &payloadBytes, limit: maximumPayloadBytes, .payloadBytes) }
    }

    private static func add(
        _ amount: UInt64, to used: inout UInt64, limit: UInt64?, _ dimension: FetchReceiveLimitExceededError.Dimension
    ) throws {
        guard let limit else { return }
        let (sum, overflow) = used.addingReportingOverflow(amount)
        guard !overflow, sum <= limit else {
            throw FetchReceiveLimitExceededError(
                dimension: dimension, limit: limit, attemptedUsage: overflow ? .max : sum
            )
        }
        used = sum
    }
}
