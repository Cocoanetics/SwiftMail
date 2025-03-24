import Foundation
import NIO

/**
 Command to authenticate with SMTP server using LOGIN method
 */
public struct LoginAuthCommand: SMTPCommand {
    /// The result type for this command
    public typealias ResultType = AuthResult
    
    /// The handler type for this command
    public typealias HandlerType = LoginAuthHandler
    
    /// Username for authentication
    public let username: String
    
    /// Password for authentication
    public let password: String
    
    /// Default timeout in seconds
    public let timeoutSeconds: Int = 30
    
    /**
     Initialize a new LOGIN authentication command
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
     */
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    /**
     Convert the command to a string to send to the server
     - Returns: The command string
     */
    public func toCommandString() -> String {
        // For LOGIN auth, the initial command doesn't include credentials
        return "AUTH LOGIN"
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
} 