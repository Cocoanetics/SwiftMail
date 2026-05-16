import Foundation
import NIOCore
import Logging

/// State machine for handling SMTP authentication processes
final class AuthHandlerStateMachine {
    /// Current state of the authentication process
    enum AuthState {
        case initial
        case usernameProvided
        case completed
    }

    /// Authentication method in use
    let method: AuthMethod

    /// Username for authentication
    let username: String

    /// Password for authentication
    let password: String

    /// Current state in the authentication process
    private var state: AuthState = .initial

    /// Initialize a new auth handler state machine
    /// - Parameters:
    ///   - method: The authentication method to use
    ///   - username: The username for authentication
    ///   - password: The password for authentication
    init(method: AuthMethod, username: String, password: String) {
        self.method = method
        self.username = username
        self.password = password
    }

    /// Process a response from the server and determine next steps
    /// - Parameters:
    ///   - response: The SMTP response to process
    ///   - sendCredential: Closure to send credentials when needed
    /// - Returns: A tuple with a boolean indicating if auth is complete and the result if complete
	func processResponse(_ response: SMTPResponse,
	                     sendCredential: (String) -> Void) -> (isComplete: Bool, result: AuthResult?) {
        switch method {
        case .plain, .xoauth2:
            return processImmediateResponse(response)
        case .login:
            return processLoginResponse(response, sendCredential: sendCredential)
        }
    }

    /// Resolve a single-shot auth method (PLAIN, XOAUTH2): success on 2xx, failure on 4xx/5xx.
    private func processImmediateResponse(_ response: SMTPResponse) -> (isComplete: Bool, result: AuthResult?) {
        if response.code >= 200 && response.code < 300 {
            return (true, AuthResult(method: method, success: true))
        } else if response.code >= 400 {
            return (true, AuthResult(method: method, success: false, errorMessage: response.message))
        }
        return (false, nil)
    }

    /// Drive the LOGIN auth state machine, optionally sending the next credential via the provided closure.
    private func processLoginResponse(
        _ response: SMTPResponse,
        sendCredential: (String) -> Void
    ) -> (isComplete: Bool, result: AuthResult?) {
        switch state {
        case .initial:
            return advanceLoginState(
                response,
                sending: username,
                sendCredential: sendCredential,
                nextState: .usernameProvided
            )
        case .usernameProvided:
            return advanceLoginState(
                response,
                sending: password,
                sendCredential: sendCredential,
                nextState: .completed
            )
        case .completed:
            return finalizeLogin(response)
        }
    }

    /// Handle a 334 challenge by sending `credential` and advancing to `nextState`; or fail on 4xx/5xx.
    private func advanceLoginState(
        _ response: SMTPResponse,
        sending credential: String,
        sendCredential: (String) -> Void,
        nextState: AuthState
    ) -> (isComplete: Bool, result: AuthResult?) {
        if response.code == 334 {
            sendCredential(credential)
            state = nextState
            return (false, nil)
        } else if response.code >= 400 {
            return (true, AuthResult(method: method, success: false, errorMessage: response.message))
        }
        return (false, nil)
    }

    /// Resolve the LOGIN flow after the password has been sent: success on 2xx, failure otherwise.
    private func finalizeLogin(_ response: SMTPResponse) -> (isComplete: Bool, result: AuthResult?) {
        if response.code >= 200 && response.code < 300 {
            return (true, AuthResult(method: method, success: true))
        }
        return (true, AuthResult(method: method, success: false, errorMessage: response.message))
    }

    /// Get the current auth state
    var currentState: AuthState {
        return state
    }
}
