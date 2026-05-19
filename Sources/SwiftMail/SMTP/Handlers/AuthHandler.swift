import Foundation
import NIOCore
import Logging

/// Handler for SMTP authentication
final class AuthHandler: BaseSMTPHandler<AuthResult>, @unchecked Sendable {
    /// Current state of the authentication process
    private enum AuthState {
        case initial
        case usernameProvided
        case completed
    }

    /// Current authentication state
    private var state: AuthState = .initial

    /// Authentication method to use
    private let method: AuthMethod

    /// Username for authentication
    private let username: String

    /// Password for authentication
    private let password: String

    /// The channel for sending commands
    private weak var channel: Channel?

    /// Initialize a new auth handler
    /// - Parameters:
    ///   - commandTag: Optional tag for the command
    ///   - promise: The promise to fulfill when the command completes
    required convenience init(commandTag: String?, promise: EventLoopPromise<AuthResult>) {
        // These will be set in the designated initializer
        self.init(commandTag: commandTag, promise: promise, method: .plain, username: "", password: "", channel: nil)
    }

    /// Designated initializer
    init(
        commandTag: String?,
        promise: EventLoopPromise<AuthResult>,
        method: AuthMethod,
        username: String,
        password: String,
        channel: Channel?
    ) {
        self.method = method
        self.username = username
        self.password = password
        self.channel = channel
        super.init(commandTag: commandTag, promise: promise)
    }

    /// Process a response line from the server.
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override func processResponse(_ response: SMTPResponse) -> Bool {
        switch method {
            case .plain, .xoauth2:
                return processOneShotResponse(response)
            case .login:
                return processLoginResponse(response)
        }
    }

    /// PLAIN/XOAUTH2: a single response decides success or failure.
    private func processOneShotResponse(_ response: SMTPResponse) -> Bool {
        if response.code >= 200 && response.code < 300 {
            promise.succeed(AuthResult(method: method, success: true))
            return true
        }
        if response.code >= 400 {
            promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
            return true
        }
        return false
    }

    /// LOGIN: multi-step state machine driven by 334 challenges.
    private func processLoginResponse(_ response: SMTPResponse) -> Bool {
        switch state {
            case .initial:
                return advanceLogin(after: response, credential: username, nextState: .usernameProvided)
            case .usernameProvided:
                return advanceLogin(after: response, credential: password, nextState: .completed)
            case .completed:
                let success = response.code >= 200 && response.code < 300
                let result = AuthResult(
                    method: method,
                    success: success,
                    errorMessage: success ? nil : response.message
                )
                promise.succeed(result)
                return true
        }
    }

    /// Shared transition logic for `.initial` and `.usernameProvided` — both
    /// expect a 334 challenge and respond with a credential.
    private func advanceLogin(
        after response: SMTPResponse,
        credential: String,
        nextState: AuthState
    ) -> Bool {
        if response.code == 334 {
            sendLoginCredential(credential)
            state = nextState
            return false
        }
        if response.code >= 400 {
            promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
            return true
        }
        return false
    }

    /// Send a credential for LOGIN authentication
    /// - Parameter credential: The credential to send (username or password)
    private func sendLoginCredential(_ credential: String) {
        guard let channel = channel else {
            promise.fail(SMTPError.connectionFailed("Channel is nil"))
            return
        }

        // Encode the credential in base64
        let base64Credential = Data(credential.utf8).base64EncodedString()

        // Send the credential
        let buffer = channel.allocator.buffer(string: base64Credential + "\r\n")
        channel.writeAndFlush(buffer).whenFailure { error in
            self.promise.fail(error)
        }
    }
}

/// Authentication methods supported by SMTP
enum AuthMethod: String {
    case plain = "PLAIN"
    case login = "LOGIN"
    case xoauth2 = "XOAUTH2"
}

/// Result of authentication attempt
struct AuthResult {
    /// Method used for authentication
    let method: AuthMethod

    /// Whether authentication was successful
    let success: Bool

    /// Error message, if authentication failed
    let errorMessage: String?

    /// Initialize a new authentication result
    /// - Parameters:
    ///   - method: Method used for authentication
    ///   - success: Whether authentication was successful
    ///   - errorMessage: Error message, if authentication failed
    init(method: AuthMethod, success: Bool, errorMessage: String? = nil) {
        self.method = method
        self.success = success
        self.errorMessage = errorMessage
    }
}
