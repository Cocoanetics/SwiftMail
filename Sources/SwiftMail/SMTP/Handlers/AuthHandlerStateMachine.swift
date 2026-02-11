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
            // For PLAIN and XOAUTH2 auth, we should get a success response immediately
            if response.code >= 200 && response.code < 300 {
                return (true, AuthResult(method: method, success: true))
            } else if response.code >= 400 {
                return (true, AuthResult(method: method, success: false, errorMessage: response.message))
            }

        case .login:
            // For LOGIN auth, we need to handle multiple steps
            switch state {
            case .initial:
                // Initial response should be a challenge for the username
                if response.code == 334 {
                    // Send the username (base64 encoded)
                    sendCredential(username)
                    state = .usernameProvided
                    return (false, nil) // Not complete yet
                } else if response.code >= 400 {
                    // Error response
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
                
            case .usernameProvided:
                // After username, should be a challenge for the password
                if response.code == 334 {
                    // Send the password (base64 encoded)
                    sendCredential(password)
                    state = .completed
                    return (false, nil) // Still need the final response
                } else if response.code >= 400 {
                    // Error response
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
                
            case .completed:
                // Final response after password
                if response.code >= 200 && response.code < 300 {
                    return (true, AuthResult(method: method, success: true))
                } else {
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
            }
        }
        
        return (false, nil) // Not yet complete
    }
    
    /// Get the current auth state
    var currentState: AuthState {
        return state
    }
} 
