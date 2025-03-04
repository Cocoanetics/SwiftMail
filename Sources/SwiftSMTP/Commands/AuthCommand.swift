import Foundation
import NIO

/**
 Command to authenticate with SMTP server
 */
public struct AuthCommand: SMTPCommand {
    /// The result type for this command
    public typealias ResultType = AuthResult
    
    /// The handler type for this command
    public typealias HandlerType = AuthHandler
    
    /// Username for authentication
    public let username: String
    
    /// Password for authentication
    public let password: String
    
    /// Authentication method to use
    public let method: AuthMethod
    
    /// Default timeout in seconds
    public let timeoutSeconds: Int = 30
    
    /**
     Initialize a new authentication command
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
       - method: The authentication method to use (default: .plain)
     */
    public init(username: String, password: String, method: AuthMethod = .plain) {
        self.username = username
        self.password = password
        self.method = method
    }
    
    /**
     Convert the command to a string to send to the server
     - Returns: The command string
     */
    public func toCommandString() -> String {
        switch method {
        case .plain:
            // For PLAIN auth, format is: \0username\0password
            let credentials = "\0\(username)\0\(password)"
            let encoded = Data(credentials.utf8).base64EncodedString()
            return "AUTH PLAIN \(encoded)"
        case .login:
            // For LOGIN auth, the initial command doesn't include credentials
            return "AUTH LOGIN"
        }
    }
    
    /**
     Validate that the command parameters are valid
     - Throws: SMTPError if validation fails
     */
    public func validate() throws {
        guard !username.isEmpty else {
            throw SMTPError.authenticationFailed("Username cannot be empty")
        }
        
        guard !password.isEmpty else {
            throw SMTPError.authenticationFailed("Password cannot be empty")
        }
    }
    
    /**
     Create a handler for this command
     - Parameters:
       - channel: The channel to use for sending commands
       - commandTag: Optional tag for the command
       - promise: The promise to fulfill when the command completes
       - timeoutSeconds: The timeout in seconds for this command
     - Returns: A handler for this command
     */
    public func createHandler(channel: Channel, commandTag: String?, promise: EventLoopPromise<AuthResult>, timeoutSeconds: Int) -> AuthHandler {
        return AuthHandler(
            commandTag: commandTag,
            promise: promise,
            timeoutSeconds: timeoutSeconds,
            method: method,
            username: username,
            password: password,
            channel: channel
        )
    }
} 