import Foundation
import NIO

/**
 Command to authenticate with SMTP server
 */
struct AuthCommand: SMTPCommand {
    /// The result type for this command
    typealias ResultType = AuthResult
    
    /// The handler type for this command
    typealias HandlerType = AuthHandler
    
    /// Username for authentication
    let username: String
    
    /// Password for authentication
    let password: String
    
    /// Authentication method to use
    let method: AuthMethod
    
    /// Default timeout in seconds
    let timeoutSeconds: Int = 30
    
    /**
     Initialize a new authentication command
     - Parameters:
       - username: The username for authentication
       - password: The password for authentication
       - method: The authentication method to use (default: .plain)
     */
    init(username: String, password: String, method: AuthMethod = .plain) {
        self.username = username
        self.password = password
        self.method = method
    }
    
    /**
     Convert the command to a string to send to the server
     - Returns: The command string
     */
    func toCommandString() -> String {
        switch method {
        case .plain:
            // For PLAIN auth, format is: \0username\0password
            let credentials = "\0\(username)\0\(password)"
            let encoded = Data(credentials.utf8).base64EncodedString()
            return "AUTH PLAIN \(encoded)"
        case .login:
            // For LOGIN auth, the initial command doesn't include credentials
            return "AUTH LOGIN"
        case .xoauth2:
            // XOAUTH2 format: user=<email>\x01auth=Bearer <token>\x01\x01
            var data = Data()
            data.append(contentsOf: "user=".utf8)
            data.append(contentsOf: username.utf8)
            data.append(0x01)
            data.append(contentsOf: "auth=Bearer ".utf8)
            data.append(contentsOf: password.utf8)
            data.append(0x01)
            data.append(0x01)
            return "AUTH XOAUTH2 \(data.base64EncodedString())"
        }
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
