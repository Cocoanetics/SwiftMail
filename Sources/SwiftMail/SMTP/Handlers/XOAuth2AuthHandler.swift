import Foundation
import NIOCore
import Logging

/// Handler for SMTP XOAUTH2 authentication.
///
/// Success is a single `235`. A rejected token, however, is answered with a
/// `334` continuation carrying a base64-encoded JSON error (Gmail sends
/// `{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}`).
/// The client must answer it with an empty line, after which the server sends
/// the final `535`. A handler that waits on the `334` without answering never
/// completes, so a wrong or expired token surfaced as a command timeout instead
/// of an authentication error.
final class XOAuth2AuthHandler: BaseSMTPHandler<AuthResult>, @unchecked Sendable {
    /// The decoded error payload of the `334` continuation, if one came.
    private var continuationError: String?

    /// The context, for answering the continuation.
    private var context: ChannelHandlerContext?

    override public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override func processResponse(_ response: SMTPResponse) -> Bool {
        if response.code >= 200 && response.code < 300 {
            promise.succeed(AuthResult(method: .xoauth2, success: true))
            return true
        }

        if response.code == 334 {
            let payload = response.message.trimmingCharacters(in: .whitespaces)
            if let data = Data(base64Encoded: payload), let decoded = String(data: data, encoding: .utf8) {
                continuationError = decoded
            } else if !payload.isEmpty {
                continuationError = payload
            }

            guard let context else {
                promise.fail(SMTPError.connectionFailed("Channel context is nil"))
                return true
            }
            // An empty line asks the server for its final reply.
            var buffer = context.channel.allocator.buffer(capacity: 2)
            buffer.writeString("\r\n")
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            return false
        }

        if response.code >= 400 {
            var message = response.message
            if let continuationError {
                message += " (\(continuationError))"
            }
            promise.succeed(AuthResult(method: .xoauth2, success: false, errorMessage: message))
            return true
        }

        return false
    }
}
