import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

/// A persistent NIO pipeline handler that buffers untagged IMAP responses
/// when no transient command handler is active.
///
/// IMAP servers can send untagged responses (EXISTS, EXPUNGE, FETCH, etc.) at any time.
/// During the gap between command handlers — for example between an IDLE cycle's DONE/NOOP
/// completing and the next IDLE starting — these responses would normally be parsed by
/// `IMAPClientHandler` but silently dropped at the pipeline tail.
///
/// This handler sits at the end of the pipeline permanently. When a command handler is active,
/// it simply passes responses through. When no command handler is active, it captures untagged
/// responses in a buffer that can be drained when the next command starts.
final class UntaggedResponseBuffer: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Response
    typealias InboundOut = Response

    private let lock = NIOLock()
    private var buffer: [Response] = []
    private var _hasActiveHandler: Bool = false
    private let logger = Logger(label: "com.cocoanetics.SwiftMail.UntaggedResponseBuffer")

    /// Whether a transient command handler is currently active in the pipeline.
    var hasActiveHandler: Bool {
        get { lock.withLock { _hasActiveHandler } }
        set { lock.withLock { _hasActiveHandler = newValue } }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)

        let shouldBuffer = lock.withLock { () -> Bool in
            guard !_hasActiveHandler else { return false }

            switch response {
            case .untagged:
                return true
            case .fetch:
                return true
            case .fatal:
                return true
            case .tagged:
                // Tagged responses should not arrive when no handler is active,
                // but don't buffer them — let them flow.
                return false
            default:
                return false
            }
        }

        if shouldBuffer {
            lock.withLock {
                buffer.append(response)
            }
            logger.debug("Buffered untagged response (no active handler): \(String(describing: response).prefix(120))")
        }

        // Always forward — if a command handler exists above us, it already processed this.
        context.fireChannelRead(data)
    }

    /// Drain all buffered responses, returning them in order.
    ///
    /// Call this when adding a new command handler to process any responses
    /// that arrived during the gap between handlers.
    func drainBuffer() -> [Response] {
        lock.withLock {
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
    }

    /// Number of currently buffered responses.
    var bufferedCount: Int {
        lock.withLock { buffer.count }
    }
}
