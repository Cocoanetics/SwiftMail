// SMTPSendError.swift
// Classified SMTP submission failure for safe retry decisions

import Foundation
import NIOCore

/// A classified failure of an SMTP message submission.
///
/// Thrown by ``SMTPServer/sendEmail(_:)`` and ``SMTPServer/sendRawMessage(_:from:to:)``
/// for every failure once the SMTP mail transaction has started (`MAIL FROM`
/// dispatched). Failures before that point — not connected, no recipients,
/// invalid addresses, message too large, 8-bit content without `8BITMIME` —
/// surface as plain ``SMTPError`` (or `CancellationError`) and can follow
/// normal retry policy.
///
/// The classification lets a durable outbox implement a retry policy without
/// parsing error-description strings:
///
/// ```swift
/// do {
///     try await smtp.sendEmail(email)
/// } catch let error as SMTPSendError {
///     switch error.retryDisposition {
///         case .retryable:     break // requeue for a later attempt
///         case .permanent:     break // do not retry this message
///         case .unsafeToRetry: break // acceptance unknown — retrying may duplicate the email
///     }
/// }
/// ```
public struct SMTPSendError: Error, Sendable, Equatable {

    /// The step of the SMTP dialogue in which the failure occurred.
    public enum Phase: Sendable, Equatable {
        /// While sending `MAIL FROM` or awaiting its reply.
        case mailFrom

        /// While sending a `RCPT TO` or awaiting its reply.
        case rcptTo

        /// While sending `DATA` or awaiting the `354` go-ahead.
        case data

        /// During the message-content step. Before the final end-of-data
        /// terminator is handed to the transport, the server cannot accept the
        /// message and failures are provably
        /// ``SMTPSendError/Acceptance-swift.enum/notAccepted``. After the
        /// terminator is handed off, failures are ambiguous unless the server
        /// sent an explicit final reply.
        case content
    }

    /// What is known about the server's acceptance of the submitted message.
    ///
    /// Named for *submission acceptance*, not delivery: even an accepted
    /// message (final 2xx, reported via ``SMTPSendResult``) may still bounce
    /// later on its way to a recipient's mailbox.
    public enum Acceptance: Sendable, Equatable {
        /// Proven: the server never received the complete message, so nothing
        /// can have been delivered. Retrying is safe.
        case notAccepted

        /// The server explicitly rejected the completed message with a final
        /// 4xx reply after the content terminator. Not accepted; retrying
        /// later is safe and may succeed.
        case rejectedTransiently

        /// The server explicitly rejected the completed message with a final
        /// 5xx reply after the content terminator. Not accepted; retrying the
        /// same message is pointless.
        case rejectedPermanently

        /// The final end-of-data terminator was handed to the transport but no
        /// clear final reply was received. The server may have accepted and
        /// delivered the message; automatically retrying risks a duplicate.
        case ambiguous
    }

    /// The submission operation whose timeout budget expired.
    public enum TimeoutStage: Sendable, Equatable {
        /// The client timed out while writing an SMTP command.
        case commandWrite

        /// The client timed out while awaiting an SMTP command reply.
        case commandResponse

        /// The client timed out while uploading one message-content buffer.
        case contentUpload

        /// The client timed out while awaiting the final reply after DATA.
        case contentResponse
    }

    /// Why the submission failed.
    public enum Reason: Sendable, Equatable {
        /// The server answered with an explicit final reply that does not
        /// indicate success. The dialogue stayed in sync.
        case reply(SMTPResponse)

        /// The surrounding task was cancelled.
        case cancelled

        /// One submission operation exceeded its timeout.
        /// See ``SMTPSendError/timeoutStage`` for the stage, when known.
        case timedOut

        /// The connection closed (EOF or already-closed channel) before a
        /// final reply arrived.
        case connectionLost

        /// Another transport or pipeline error (e.g. a TLS failure). The
        /// associated string is diagnostic only and carries no information
        /// needed for retry classification.
        case transport(String)
    }

    /// The retry policy implied by a classified outcome.
    public enum RetryDisposition: Sendable, Equatable {
        /// The server did not accept the message; retrying is safe.
        case retryable

        /// The server rejected the message permanently; do not retry.
        case permanent

        /// Acceptance is unknown; an automatic retry could deliver the message
        /// twice. Reconcile out of band (e.g. operator review or checking the
        /// recipient/Sent state) before resending.
        case unsafeToRetry
    }

    /// The step of the SMTP dialogue in which the failure occurred.
    public let phase: Phase

    /// What is known about the server's acceptance of the message.
    public let acceptance: Acceptance

    /// Why the submission failed.
    public let reason: Reason

    /// The submission operation whose timeout budget expired. Set when
    /// ``reason-swift.property`` is ``Reason-swift.enum/timedOut`` and the
    /// timeout originated from SwiftMail's submission executor.
    public let timeoutStage: TimeoutStage?

    /// The recipient whose `RCPT TO` was explicitly rejected. Set only when
    /// ``phase-swift.property`` is ``Phase-swift.enum/rcptTo`` and
    /// ``reason-swift.property`` carries a server reply.
    public let rejectedRecipient: EmailAddress?

    /// The explicit final server reply, when the failure carried one.
    public var response: SMTPResponse? {
        if case .reply(let response) = reason {
            return response
        }
        return nil
    }

    /// The retry policy implied by ``acceptance-swift.property`` — and, for
    /// proven non-acceptance replies, by the reply code (5xx is permanent).
    public var retryDisposition: RetryDisposition {
        switch acceptance {
            case .ambiguous:
                return .unsafeToRetry
            case .rejectedPermanently:
                return .permanent
            case .rejectedTransiently:
                return .retryable
            case .notAccepted:
                if let code = response?.code, (500...599).contains(code) {
                    return .permanent
                }
                return .retryable
        }
    }

    /// Create a send error. Public so callers can fabricate outcomes when
    /// testing their own retry policies.
    public init(
        phase: Phase,
        acceptance: Acceptance,
        reason: Reason,
        rejectedRecipient: EmailAddress? = nil,
        timeoutStage: TimeoutStage? = nil
    ) {
        self.phase = phase
        self.acceptance = acceptance
        self.reason = reason
        self.rejectedRecipient = rejectedRecipient
        self.timeoutStage = timeoutStage
    }
}

// MARK: - Descriptions

extension SMTPSendError: CustomStringConvertible {
    public var description: String {
        var text = "SMTP send failed during \(phase)"
        if let rejectedRecipient {
            text += " for <\(rejectedRecipient.address)>"
        }
        switch reason {
            case .reply(let response):
                text += ": server replied \(response.code) \(response.message)"
            case .cancelled:
                text += ": cancelled"
            case .timedOut:
                switch timeoutStage {
                    case .commandWrite:
                        text += ": timed out writing the SMTP command"
                    case .commandResponse:
                        text += ": timed out waiting for the server's reply"
                    case .contentUpload:
                        text += ": timed out uploading message content"
                    case .contentResponse:
                        text += ": timed out waiting for the final server reply"
                    case nil:
                        text += ": timed out"
                }
            case .connectionLost:
                text += ": connection lost"
            case .transport(let diagnostic):
                text += ": transport error: \(diagnostic)"
        }
        return text + " (\(acceptance))"
    }
}

// LocalizedError so .localizedDescription returns the real message (not just "error N")
extension SMTPSendError: LocalizedError {
    public var errorDescription: String? { description }
}

extension SMTPSendError.Phase: CustomStringConvertible {
    public var description: String {
        switch self {
            case .mailFrom:
                return "MAIL FROM"
            case .rcptTo:
                return "RCPT TO"
            case .data:
                return "DATA"
            case .content:
                return "message content"
        }
    }
}

extension SMTPSendError.Acceptance: CustomStringConvertible {
    public var description: String {
        switch self {
            case .notAccepted:
                return "message not accepted by the server"
            case .rejectedTransiently:
                return "message rejected transiently"
            case .rejectedPermanently:
                return "message rejected permanently"
            case .ambiguous:
                return "acceptance unknown, retrying may duplicate the message"
        }
    }
}

// MARK: - Internal classification

/// Marker failure used by the submission executor so the classifier can
/// preserve which timeout budget expired without matching error strings.
struct SMTPSubmissionTimeoutError: Error {
    let stage: SMTPSendError.TimeoutStage
}

extension SMTPSendError.Reason {
    /// Derive the reason from an error surfaced by the submission dialogue.
    init(classifying error: Error) {
        if case SMTPError.unexpectedResponse(let response) = error {
            self = .reply(response)
        } else if error is CancellationError {
            self = .cancelled
        } else if error is SMTPSubmissionTimeoutError {
            self = .timedOut
        } else if case SMTPError.connectionFailed = error {
            // Within the submission dialogue this only arises from the channel
            // going away (BaseSMTPHandler.channelInactive or a vanished channel).
            self = .connectionLost
        } else if let channelError = error as? ChannelError {
            switch channelError {
                case .ioOnClosedChannel, .alreadyClosed, .inputClosed, .outputClosed, .eof:
                    self = .connectionLost
                default:
                    self = .transport(String(describing: error))
            }
        } else {
            self = .transport(String(describing: error))
        }
    }
}

extension SMTPSendError {
    /// Classify a failure for which the server provably could not have accepted
    /// the complete message. This includes all command phases before DATA and
    /// content upload failures before the final end-of-data terminator.
    static func classifyingProvenNonAcceptance(
        _ error: Error,
        phase: Phase,
        recipient: EmailAddress? = nil
    ) -> SMTPSendError {
        let reason = Reason(classifying: error)
        let rejectedRecipient: EmailAddress?
        if phase == .rcptTo, case .reply = reason {
            rejectedRecipient = recipient
        } else {
            // A timeout or transport loss during RCPT TO is not a rejection
            // of that recipient.
            rejectedRecipient = nil
        }
        return SMTPSendError(
            phase: phase,
            acceptance: .notAccepted,
            reason: reason,
            rejectedRecipient: rejectedRecipient,
            timeoutStage: (error as? SMTPSubmissionTimeoutError)?.stage
        )
    }

    /// Classify a content-phase failure according to whether the final SMTP
    /// end-of-data terminator may have been handed to the transport.
    static func classifyingContentFailure(
        _ error: Error,
        endOfDataMayHaveBeenDispatched: Bool
    ) -> SMTPSendError {
        if endOfDataMayHaveBeenDispatched {
            return classifyingPostEndOfDataDispatch(error)
        }
        return classifyingProvenNonAcceptance(error, phase: .content)
    }

    /// Classify a failure that happened after the final end-of-data terminator
    /// was handed to the transport. Only an explicit 4xx/5xx reply proves the
    /// server rejected the message; every other outcome is ``Acceptance-swift.enum/ambiguous``
    /// because the terminating dot may have reached the server (NIO and TLS
    /// buffering make the opposite unprovable client-side).
    static func classifyingPostEndOfDataDispatch(_ error: Error) -> SMTPSendError {
        let reason = Reason(classifying: error)
        let acceptance: Acceptance
        if case .reply(let response) = reason {
            switch response.code {
                case 400...499:
                    acceptance = .rejectedTransiently
                case 500...599:
                    acceptance = .rejectedPermanently
                default:
                    // A malformed or intermediate reply after the terminator
                    // proves nothing about acceptance.
                    acceptance = .ambiguous
            }
        } else {
            acceptance = .ambiguous
        }
        return SMTPSendError(
            phase: .content,
            acceptance: acceptance,
            reason: reason,
            timeoutStage: (error as? SMTPSubmissionTimeoutError)?.stage
        )
    }
}
