import Foundation

/// Opt-in ceilings on what one metadata FETCH call may receive.
///
/// Pass these to the `limits:` overloads of ``IMAPServer/fetchMessageInfosBulk(using:options:headerFields:limits:)``
/// and the other metadata FETCH calls on ``IMAPServer`` and ``IMAPNamedConnection``. Both
/// ceilings are optional and independent; `nil` leaves that dimension unbounded, as the overloads
/// without `limits:` always do. Each ceiling is a maximum: exactly the limit is allowed, one more
/// fails with ``FetchReceiveLimitExceededError``.
///
/// One call owns one budget. A streaming call that sends one FETCH per chunk draws every chunk
/// from the same budget; a separate call starts with a fresh one.
///
/// ## What counts
/// - ``maximumReplies`` counts each FETCH reply (`* n FETCH (...)`) the call receives, including
///   repeated and unsolicited replies for messages it did not ask for.
/// - ``maximumPayloadBytes`` counts the size each streamed section declares, such as the
///   `BODY[HEADER]` or `BODY[HEADER.FIELDS (...)]` literal, whether SwiftMail keeps that section
///   or not. It is checked when the section begins, before its bytes are read.
///
/// ## What does not count
/// ``maximumPayloadBytes`` is not a bound on heap usage or on bytes read from the network. It
/// does not include strings and literals nested inside ENVELOPE or BODYSTRUCTURE, which the
/// parser has already turned into values before SwiftMail sees them; those stay bounded by
/// ``IMAPParserLimits`` per response.
public struct FetchReceiveLimits: Sendable, Equatable {
    /// The most FETCH replies the call may receive, or `nil` for no limit. Zero is allowed and
    /// fails on the first reply; a negative value fails the call with `IMAPError.invalidArgument`.
    public let maximumReplies: Int?

    /// The most streamed-section bytes the call may receive, by the sizes the server declares,
    /// or `nil` for no limit. Zero is allowed and fails on the first non-empty section.
    public let maximumPayloadBytes: UInt64?

    /// No limits: the behaviour of the overloads without `limits:`.
    public static let unlimited = FetchReceiveLimits()

    public init(maximumReplies: Int? = nil, maximumPayloadBytes: UInt64? = nil) {
        self.maximumReplies = maximumReplies
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

/// A metadata FETCH call received more than its ``FetchReceiveLimits`` allow.
///
/// Raised by the reply or section that goes past the limit, before it is kept. The call fails as
/// a whole, without returning the messages received so far, and the connection it used is
/// closed; the next command on that connection follows its reconnect policy. A stream yields
/// what earlier chunks returned and then finishes with this error.
public struct FetchReceiveLimitExceededError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Which ceiling was exceeded.
    public enum Dimension: Sendable, Equatable {
        /// ``FetchReceiveLimits/maximumReplies``.
        case replies
        /// ``FetchReceiveLimits/maximumPayloadBytes``.
        case payloadBytes
    }

    /// Which ceiling was exceeded.
    public let dimension: Dimension

    /// The configured limit.
    public let limit: UInt64

    /// The usage the rejected reply or section would have brought the call to: replies, or
    /// declared bytes. `UInt64.max` when the sum overflows.
    public let attemptedUsage: UInt64

    public init(dimension: Dimension, limit: UInt64, attemptedUsage: UInt64) {
        self.dimension = dimension
        self.limit = limit
        self.attemptedUsage = attemptedUsage
    }

    public var description: String {
        switch dimension {
            case .replies:
                return "Metadata FETCH received \(attemptedUsage) replies, exceeding the limit of \(limit)"
            case .payloadBytes:
                return "Metadata FETCH received \(attemptedUsage) bytes of streamed sections, "
                    + "exceeding the limit of \(limit)"
        }
    }
}
