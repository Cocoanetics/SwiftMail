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

    /// The context, for answering the continuation. A context retains its handler, so
    /// this is cleared when the handler leaves the pipeline; keeping it would hold the
    /// handler, its promise and the pipeline for as long as the process lives.
    private var context: ChannelHandlerContext?

    override public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    override public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
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
            let payload = Self.continuationPayload(of: response)
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

    /// The text of a `334` reply without its reply code. `SMTPResponseHandler` hands
    /// over the reply as it came, so `message` is `334 eyJ…`, not `eyJ…`; each line of
    /// a multi-line reply carries the code, followed by `-` or a space.
    static func continuationPayload(of response: SMTPResponse) -> String {
        let code = String(response.code)
        return response.message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard line.hasPrefix(code) else { return line }
                let rest = line.dropFirst(code.count)
                guard let separator = rest.first else { return rest }
                return separator == " " || separator == "-" ? rest.dropFirst() : line
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
