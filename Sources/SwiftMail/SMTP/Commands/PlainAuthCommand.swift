import Foundation
import NIO

/**
 Command to authenticate with SMTP server using PLAIN method
 */
struct PlainAuthCommand: SMTPCommand {
    /// The result type for this command
    typealias ResultType = AuthResult
    
    /// The handler type for this command
    typealias HandlerType = PlainAuthHandler
    
    /// Username for authentication
    let username: String
    
    /// Password for authentication
    let password: String
    
    /// Default timeout in seconds
    let timeoutSeconds: Int = 30
    
    /**
     Initialize a new PLAIN authentication command
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
     */
    init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    /**
     Convert the command to a string to send to the server
     - Returns: The command string
     */
    func toCommandString() -> String {
        // For PLAIN auth, format should be: \0username\0password
        // The proper format is actually: \0<authzid>\0<authcid>\0<passwd>
        // where authzid can be empty, and authcid is the username
        let authzid = "" // Authorization identity (usually empty)
        let authcid = username // Authentication identity (username)
        let passwd = password
        
        // Build the credentials string with null bytes
        let credentialsString = "\(authzid)\0\(authcid)\0\(passwd)"
        
        // Convert to data with proper UTF-8 encoding
        let credentialsData = credentialsString.data(using: .utf8)!
        
        // Base64 encode the data
        let encoded = credentialsData.base64EncodedString()
        
        return "AUTH PLAIN \(encoded)"
    }
    
    /**
     Validate that the command parameters are valid
     - Throws: SMTPError if validation fails
     */
    func validate() throws {
        guard !username.isEmpty else {
            throw SMTPError.authenticationFailed("Username cannot be empty")
        }
        
        guard !password.isEmpty else {
            throw SMTPError.authenticationFailed("Password cannot be empty")
        }
    }
} 
