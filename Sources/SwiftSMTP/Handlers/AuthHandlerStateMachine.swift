import Foundation
import NIOCore
import Logging

/// State machine for handling SMTP authentication processes
public class AuthHandlerStateMachine {
    /// Current state of the authentication process
    public enum AuthState {
        case initial
        case usernameProvided
        case completed
    }
    
    /// Authentication method in use
    public let method: AuthMethod
    
    /// Username for authentication
    public let username: String
    
    /// Password for authentication
    public let password: String
    
    /// Current state in the authentication process
    private var state: AuthState = .initial
    
    /// Logger for this state machine
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.AuthHandlerStateMachine")
    
    /// Initialize a new auth handler state machine
    /// - Parameters:
    ///   - method: The authentication method to use
    ///   - username: The username for authentication
    ///   - password: The password for authentication
    public init(method: AuthMethod, username: String, password: String) {
        self.method = method
        self.username = username
        self.password = password
        logger.debug("Initialized AuthHandlerStateMachine with method: \(method.rawValue)")
    }
    
    /// Process a response from the server and determine next steps
    /// - Parameters:
    ///   - response: The SMTP response to process
    ///   - sendCredential: Closure to send credentials when needed
    /// - Returns: A tuple with a boolean indicating if auth is complete and the result if complete
    public func processResponse(_ response: SMTPResponse, 
                               sendCredential: (String) -> Void) -> (isComplete: Bool, result: AuthResult?) {
        logger.debug("Processing response in state \(state): \(response.code) \(response.message)")
        
        switch method {
        case .plain:
            // For PLAIN auth, we should get a success response immediately
            if response.code >= 200 && response.code < 300 {
                logger.info("PLAIN auth succeeded with code \(response.code)")
                return (true, AuthResult(method: method, success: true))
            } else if response.code >= 400 {
                logger.warning("PLAIN auth failed with code \(response.code): \(response.message)")
                return (true, AuthResult(method: method, success: false, errorMessage: response.message))
            }
            
        case .login:
            // For LOGIN auth, we need to handle multiple steps
            switch state {
            case .initial:
                // Initial response should be a challenge for the username
                if response.code == 334 {
                    logger.debug("LOGIN auth: Received username challenge, sending username")
                    // Send the username (base64 encoded)
                    sendCredential(username)
                    state = .usernameProvided
                    return (false, nil) // Not complete yet
                } else if response.code >= 400 {
                    // Error response
                    logger.warning("LOGIN auth failed at initial state: \(response.message)")
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
                
            case .usernameProvided:
                // After username, should be a challenge for the password
                if response.code == 334 {
                    logger.debug("LOGIN auth: Received password challenge, sending password")
                    // Send the password (base64 encoded)
                    sendCredential(password)
                    state = .completed
                    return (false, nil) // Still need the final response
                } else if response.code >= 400 {
                    // Error response
                    logger.warning("LOGIN auth failed after username: \(response.message)")
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
                
            case .completed:
                // Final response after password
                if response.code >= 200 && response.code < 300 {
                    logger.info("LOGIN auth succeeded with code \(response.code)")
                    return (true, AuthResult(method: method, success: true))
                } else {
                    logger.warning("LOGIN auth failed after password: \(response.message)")
                    return (true, AuthResult(method: method, success: false, errorMessage: response.message))
                }
            }
        }
        
        logger.debug("Auth not yet complete, continuing")
        return (false, nil) // Not yet complete
    }
    
    /// Get the current auth state
    public var currentState: AuthState {
        return state
    }
} 