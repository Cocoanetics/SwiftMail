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
    init(commandTag: String?, promise: EventLoopPromise<AuthResult>,
               method: AuthMethod, username: String, password: String, channel: Channel?) {
        self.method = method
        self.username = username
        self.password = password
        self.channel = channel
        super.init(commandTag: commandTag, promise: promise)
    }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override func processResponse(_ response: SMTPResponse) -> Bool {
        // Handle authentication based on the method and current state
        switch method {
        case .plain, .xoauth2:
            // For PLAIN and XOAUTH2 auth, we should get a success response immediately
            if response.code >= 200 && response.code < 300 {
                promise.succeed(AuthResult(method: method, success: true))
                return true
            } else if response.code >= 400 {
                promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                return true
            }

        case .login:
            // For LOGIN auth, we need to handle multiple steps
            switch state {
            case .initial:
                // Initial response should be a challenge for the username
                if response.code == 334 {
                    // Send the username (base64 encoded)
                    sendLoginCredential(username)
                    state = .usernameProvided
                    return false // Not complete yet
                } else if response.code >= 400 {
                    // Error response
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
                
            case .usernameProvided:
                // After username, should be a challenge for the password
                if response.code == 334 {
                    // Send the password (base64 encoded)
                    sendLoginCredential(password)
                    state = .completed
                    return false // Still need the final response
                } else if response.code >= 400 {
                    // Error response
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
                
            case .completed:
                // Final response after password
                if response.code >= 200 && response.code < 300 {
                    promise.succeed(AuthResult(method: method, success: true))
                    return true
                } else {
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
            }
        }
        
        return false // Not yet complete
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
