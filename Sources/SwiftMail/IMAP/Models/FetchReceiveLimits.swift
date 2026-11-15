import Foundation

/// Opt-in ceilings on what one metadata FETCH call may receive.
///
/// Pass these as the `limits:` parameter of the metadata FETCH calls on ``IMAPServer`` and
/// ``IMAPNamedConnection``. Both ceilings are optional, independent and inclusive: exactly the
/// limit is allowed, one more fails with ``FetchReceiveLimitExceededError``. One call owns one
/// budget, shared by every chunk it fetches; a separate call starts afresh.
///
/// - ``maximumReplies`` counts each FETCH reply the call receives, unsolicited ones included.
/// - ``maximumPayloadBytes`` counts the size each streamed section (such as `BODY[HEADER]`)
///   declares, whether SwiftMail keeps it or not, checked before its bytes are read.
///
/// ``maximumPayloadBytes`` is not a bound on heap usage or network bytes. Literals nested inside
/// ENVELOPE or BODYSTRUCTURE are not counted; ``IMAPParserLimits`` bound those per response.
public struct FetchReceiveLimits: Sendable, Equatable {
    /// The most FETCH replies, or `nil` for no limit. Negative values fail with `IMAPError.invalidArgument`.
    public let maximumReplies: Int?

    /// The most declared streamed-section bytes, or `nil` for no limit.
    public let maximumPayloadBytes: UInt64?

    /// No limits: the default.
    public static let unlimited = FetchReceiveLimits()

    public init(maximumReplies: Int? = nil, maximumPayloadBytes: UInt64? = nil) {
        self.maximumReplies = maximumReplies
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

/// A metadata FETCH call received more than its ``FetchReceiveLimits`` allow.
///
/// Raised before the offending reply or section is kept. The call returns nothing it received,
/// and the connection it used is closed; the next command follows the reconnect policy.
public struct FetchReceiveLimitExceededError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Which ceiling was exceeded.
    public enum Dimension: Sendable, Equatable {
        case replies
        case payloadBytes
    }

    public let dimension: Dimension

    /// The configured limit.
    public let limit: UInt64

    /// The usage the rejected reply or section would have reached; `UInt64.max` on overflow.
    public let attemptedUsage: UInt64

    public init(dimension: Dimension, limit: UInt64, attemptedUsage: UInt64) {
        self.dimension = dimension
        self.limit = limit
        self.attemptedUsage = attemptedUsage
    }

    public var description: String {
        "Metadata FETCH reached \(attemptedUsage) \(dimension == .replies ? "replies" : "payload bytes"), "
            + "exceeding the limit of \(limit)"
    }
}
