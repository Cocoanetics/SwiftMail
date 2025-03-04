import Foundation
import NIOCore
import Logging

/// Handler for SMTP authentication
public class AuthHandler: BaseSMTPHandler<AuthResult> {
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
    ///   - timeoutSeconds: The timeout in seconds for this command
    ///   - method: Authentication method to use
    ///   - username: Username for authentication
    ///   - password: Password for authentication
    ///   - channel: Channel for sending commands
    public required init(commandTag: String?, promise: EventLoopPromise<AuthResult>, timeoutSeconds: Int = 30) {
        // These will be set in the designated initializer
        self.method = .plain
        self.username = ""
        self.password = ""
        self.channel = nil
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
        print("DEBUG - AuthHandler initialized with required initializer (incomplete)")
        logger.debug("AuthHandler initialized with required initializer (incomplete)")
    }
    
    /// Designated initializer
    public init(commandTag: String?, promise: EventLoopPromise<AuthResult>, timeoutSeconds: Int = 30, 
               method: AuthMethod, username: String, password: String, channel: Channel) {
        self.method = method
        self.username = username
        self.password = password
        self.channel = channel
        super.init(commandTag: commandTag, promise: promise, timeoutSeconds: timeoutSeconds)
        print("DEBUG - AuthHandler initialized with method: \(method), username: \(username), channel: \(channel)")
        logger.debug("AuthHandler initialized with method: \(method), username: \(username), channel: \(channel)")
    }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        print("DEBUG - Processing response: \(response.code) \(response.message)")
        logger.debug("Processing response: \(response.code) \(response.message)")
        
        // Handle authentication based on the method and current state
        switch method {
        case .plain:
            // For PLAIN auth, we should get a success response immediately
            if response.code >= 200 && response.code < 300 {
                print("DEBUG - PLAIN authentication successful")
                logger.info("PLAIN authentication successful")
                promise.succeed(AuthResult(method: method, success: true))
                return true
            } else if response.code >= 400 {
                print("DEBUG - PLAIN authentication failed: \(response.message)")
                logger.warning("PLAIN authentication failed: \(response.message)")
                promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                return true
            }
            
        case .login:
            // For LOGIN auth, we need to handle multiple steps
            switch state {
            case .initial:
                // Initial response should be a challenge for the username
                if response.code == 334 {
                    print("DEBUG - LOGIN auth: Received username challenge")
                    logger.debug("LOGIN auth: Received username challenge")
                    // Send the username (base64 encoded)
                    sendLoginCredential(username)
                    state = .usernameProvided
                    return false // Not complete yet
                } else if response.code >= 400 {
                    // Error response
                    print("DEBUG - LOGIN authentication failed at initial step: \(response.message)")
                    logger.warning("LOGIN authentication failed at initial step: \(response.message)")
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
                
            case .usernameProvided:
                // After username, should be a challenge for the password
                if response.code == 334 {
                    print("DEBUG - LOGIN auth: Received password challenge")
                    logger.debug("LOGIN auth: Received password challenge")
                    // Send the password (base64 encoded)
                    sendLoginCredential(password)
                    state = .completed
                    return false // Still need the final response
                } else if response.code >= 400 {
                    // Error response
                    print("DEBUG - LOGIN authentication failed after username: \(response.message)")
                    logger.warning("LOGIN authentication failed after username: \(response.message)")
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
                
            case .completed:
                // Final response after password
                if response.code >= 200 && response.code < 300 {
                    print("DEBUG - LOGIN authentication successful")
                    logger.info("LOGIN authentication successful")
                    promise.succeed(AuthResult(method: method, success: true))
                    return true
                } else {
                    print("DEBUG - LOGIN authentication failed after password: \(response.message)")
                    logger.warning("LOGIN authentication failed after password: \(response.message)")
                    promise.succeed(AuthResult(method: method, success: false, errorMessage: response.message))
                    return true
                }
            }
        }
        
        print("DEBUG - Authentication not yet complete, continuing")
        logger.debug("Authentication not yet complete, continuing")
        return false // Not yet complete
    }
    
    /// Send a credential for LOGIN authentication
    /// - Parameter credential: The credential to send (username or password)
    private func sendLoginCredential(_ credential: String) {
        guard let channel = channel else {
            print("DEBUG - Cannot send credential: Channel is nil")
            logger.error("Cannot send credential: Channel is nil")
            promise.fail(SMTPError.connectionFailed("Channel is nil"))
            return
        }
        
        // Encode the credential in base64
        let base64Credential = Data(credential.utf8).base64EncodedString()
        print("DEBUG - Sending credential (base64 encoded)")
        logger.debug("Sending credential (base64 encoded)")
        
        // Send the credential
        let buffer = channel.allocator.buffer(string: base64Credential + "\r\n")
        channel.writeAndFlush(buffer).whenFailure { error in
            print("DEBUG - Failed to send credential: \(error.localizedDescription)")
            self.logger.error("Failed to send credential: \(error.localizedDescription)")
            self.promise.fail(error)
        }
    }
}

/// Authentication methods supported by SMTP
public enum AuthMethod: String {
    case plain = "PLAIN"
    case login = "LOGIN"
}

/// Result of authentication attempt
public struct AuthResult {
    /// Method used for authentication
    public let method: AuthMethod
    
    /// Whether authentication was successful
    public let success: Bool
    
    /// Error message, if authentication failed
    public let errorMessage: String?
    
    /// Initialize a new authentication result
    /// - Parameters:
    ///   - method: Method used for authentication
    ///   - success: Whether authentication was successful
    ///   - errorMessage: Error message, if authentication failed
    public init(method: AuthMethod, success: Bool, errorMessage: String? = nil) {
        self.method = method
        self.success = success
        self.errorMessage = errorMessage
    }
} 