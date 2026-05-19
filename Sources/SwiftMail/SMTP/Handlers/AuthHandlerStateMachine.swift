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

    /// Process a response from the server and determine next steps.
    /// - Parameters:
    ///   - response: The SMTP response to process
    ///   - sendCredential: Closure to send credentials when needed
    /// - Returns: A tuple with a boolean indicating if auth is complete and the result if complete
    func processResponse(
        _ response: SMTPResponse,
        sendCredential: (String) -> Void
    ) -> (isComplete: Bool, result: AuthResult?) {
        switch method {
            case .plain, .xoauth2:
                return processOneShotResponse(response)
            case .login:
                return processLoginResponse(response, sendCredential: sendCredential)
        }
    }

    /// Outcome for PLAIN/XOAUTH2: a single response decides success or failure.
    private func processOneShotResponse(_ response: SMTPResponse) -> (isComplete: Bool, result: AuthResult?) {
        if response.code >= 200 && response.code < 300 {
            return (true, AuthResult(method: method, success: true))
        }
        if response.code >= 400 {
            return (true, AuthResult(method: method, success: false, errorMessage: response.message))
        }
        return (false, nil)
    }

    /// Outcome for LOGIN: multi-step state machine driven by 334 challenges.
    private func processLoginResponse(
        _ response: SMTPResponse,
        sendCredential: (String) -> Void
    ) -> (isComplete: Bool, result: AuthResult?) {
        switch state {
            case .initial:
                return advanceLogin(
                    after: response,
                    credential: username,
                    nextState: .usernameProvided,
                    sendCredential: sendCredential
                )
            case .usernameProvided:
                return advanceLogin(
                    after: response,
                    credential: password,
                    nextState: .completed,
                    sendCredential: sendCredential
                )
            case .completed:
                let success = response.code >= 200 && response.code < 300
                let result = AuthResult(
                    method: method,
                    success: success,
                    errorMessage: success ? nil : response.message
                )
                return (true, result)
        }
    }

    /// Shared transition logic for `.initial` and `.usernameProvided` — both
    /// expect a 334 challenge and respond with a credential.
    private func advanceLogin(
        after response: SMTPResponse,
        credential: String,
        nextState: AuthState,
        sendCredential: (String) -> Void
    ) -> (isComplete: Bool, result: AuthResult?) {
        if response.code == 334 {
            sendCredential(credential)
            state = nextState
            return (false, nil)
        }
        if response.code >= 400 {
            return (true, AuthResult(method: method, success: false, errorMessage: response.message))
        }
        return (false, nil)
    }

    /// Get the current auth state
    var currentState: AuthState {
        return state
    }
}
