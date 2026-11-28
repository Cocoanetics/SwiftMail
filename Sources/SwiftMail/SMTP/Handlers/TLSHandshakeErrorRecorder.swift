import NIO
import NIOTLS

/**
 Keeps the first error reported on the channel while a STARTTLS handshake runs.

 After `STARTTLS` the client sends its next `EHLO` without waiting for the
 handshake to finish. When the handshake fails, NIOSSL reports the cause on the
 pipeline's error path and then closes the channel, so the `EHLO` only sees the
 closed channel. Installed directly after the TLS handler, this handler keeps that
 cause so a failed upgrade can report it; it is read only then. It stops recording
 once the handshake completes: a later failure, such as a server reply followed by
 a close without a TLS close notification, is reported by the command that saw it.
 It adds no wait and changes no order: the upgrade runs exactly as before, and this
 handler passes everything on.
 */
final class TLSHandshakeErrorRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let eventLoop: EventLoop

    // Read and written on `eventLoop` only.
    private var firstError: Error?
    private var handshakeCompleted = false

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .handshakeCompleted? = event as? TLSUserEvent {
            handshakeCompleted = true
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !handshakeCompleted, firstError == nil {
            firstError = error
        }
        context.fireErrorCaught(error)
    }

    /// The first error reported before the handshake completed, if any.
    func recordedError() async -> Error? {
        try? await eventLoop.submit { self.firstError }.get()
    }
}
