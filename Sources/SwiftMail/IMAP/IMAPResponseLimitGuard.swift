import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import Logging

/// Enforces ``IMAPParserLimits/bodySizeLimit`` across a whole FETCH response, and makes every
/// parser-limit violation fail closed.
///
/// ## Why this exists at the pipeline level
/// `ResponseParser` applies `bodySizeLimit` to **each streaming body section on its own** and
/// keeps no response-wide total. SwiftMail's own consumers, meanwhile, accumulate: both
/// `FetchPartHandler` and `PipelinedFetchPartHandler` append every streaming attribute into a
/// single `Data` until the FETCH finishes. So with `bodySizeLimit: 64 MiB` a server could return
/// any number of 50 MiB sections in one FETCH — each one passing the check, all of them landing
/// in one buffer. The documented memory guard was bypassable.
///
/// The total could be counted in those two handlers, but then it would hold only for the two
/// that exist today, and only for as long as nobody adds a third. The limit is a **transport**
/// promise — `IMAPServer` documents it as server-level policy — so it is enforced on the
/// transport, once, for every consumer including future ones.
///
/// ## Why it also closes the connection
/// Because a limit that is reported but not acted on is not a limit. Parser-limit errors
/// previously did not fail closed: during IDLE, `IdleHandler.errorCaught` only failed a private
/// promise that nothing was awaiting until a later DONE, while the decoder kept the rejected
/// bytes and appended every subsequent read to them before raising the same error again — the
/// post-decode buffer cap is skipped when decoding throws. A peer could keep growing memory
/// while the caller's `AsyncStream` sat there waiting. The guard therefore closes the channel on
/// any limit violation: the connection has already proven it is hostile or broken, and the one
/// thing that must not happen is to keep reading from it.
final class IMAPResponseLimitGuard: ChannelInboundHandler {
    typealias InboundIn = Response
    typealias InboundOut = Response

    /// The aggregate ceiling for one FETCH response. `nil` = unbounded (`.max`), the default.
    private let bodySizeLimit: UInt64?

    /// Bytes declared by streaming sections of the FETCH response currently being parsed.
    private var accumulated: UInt64 = 0

    private let logger: Logging.Logger
    private let connectionContext: String

    init(bodySizeLimit: UInt64, logger: Logging.Logger, connectionContext: String) {
        self.bodySizeLimit = bodySizeLimit == .max ? nil : bodySizeLimit
        self.logger = logger
        self.connectionContext = connectionContext
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        if let bodySizeLimit, case .fetch(let fetch) = response {
            switch fetch {
                case .start, .startUID:
                    // A new message's FETCH begins — the total is per response, not per session.
                    accumulated = 0

                case .streamingBegin(_, let byteCount):
                    // `byteCount` is what the server *declares*, which is exactly what has to be
                    // bounded: acting on the declaration is the whole point of a limit. The
                    // bytes themselves arrive afterwards, and by then the allocation is decided.
                    accumulated += UInt64(max(0, byteCount))
                    if accumulated > bodySizeLimit {
                        fail(
                            context: context,
                            error: ExceededResponseBodySizeError(
                                accumulatedCount: accumulated,
                                maximumCount: bodySizeLimit
                            )
                        )
                        return
                    }

                case .finish:
                    accumulated = 0

                default:
                    break
            }
        }

        context.fireChannelRead(wrapInboundOut(response))
    }

    /// Parser-limit errors from the decoder pass through here on their way up the pipeline.
    ///
    /// They are forwarded — the command handlers still need to fail their promises — and *then*
    /// the channel is closed. Without the close, the decoder keeps the rejected bytes and every
    /// further read is appended to them.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard Self.isLimitViolation(error) else {
            context.fireErrorCaught(error)
            return
        }
        fail(context: context, error: error)
    }

    private func fail(context: ChannelHandlerContext, error: Error) {
        logger.warning("\(connectionContext) Parser limit exceeded, closing connection: \(error)")
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }

    /// Is this one of the errors our limits produce?
    ///
    /// Deliberately narrow: only errors that mean *„this peer sent more than we allow"*. A
    /// connection is not torn down for anything else — `errorCaught` sees unrelated failures too,
    /// and closing on those would change behaviour far outside this feature.
    static func isLimitViolation(_ error: Error) -> Bool {
        error is ExceededMaximumBodySizeError
            || error is ExceededMaximumMessageAttributesError
            || error is ExceededResponseBodySizeError
    }
}

/// The whole FETCH response declared more body data than ``IMAPParserLimits/bodySizeLimit``.
///
/// Distinct from NIOIMAPCore's `ExceededMaximumBodySizeError`, which reports a *single* section
/// exceeding the limit. This one reports the total across the response — the case the parser
/// cannot see, because it never accumulates.
public struct ExceededResponseBodySizeError: Error, Equatable, CustomStringConvertible {
    /// Bytes declared so far by streaming sections of this FETCH response.
    public let accumulatedCount: UInt64

    /// The configured ``IMAPParserLimits/bodySizeLimit``.
    public let maximumCount: UInt64

    public var description: String {
        "FETCH response declared \(accumulatedCount) bytes of body data across its sections, "
            + "exceeding the configured limit of \(maximumCount)"
    }
}
