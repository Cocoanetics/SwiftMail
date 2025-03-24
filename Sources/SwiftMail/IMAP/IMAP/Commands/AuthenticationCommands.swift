// AuthenticationCommands.swift
// Commands related to IMAP authentication

import Foundation
import NIO
import NIOIMAP

/// Command for logging into an IMAP server
struct LoginCommand: IMAPCommand {
    typealias ResultType = [Capability]
    typealias HandlerType = LoginHandler
    
    /// The username for authentication
    let username: String
    
    /// The password for authentication
    let password: String
    
    /// The handler type for processing this command
   var handlerType: HandlerType.Type { LoginHandler.self }
    
    /// Initialize a new login command
    /// - Parameters:
    ///   - username: The username for authentication
    ///   - password: The password for authentication
   init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .login(
            username: username,
            password: password
        ))
    }
}

/// Command for logging out of an IMAP server
struct LogoutCommand: IMAPCommand {
    typealias ResultType = Void
    typealias HandlerType = LogoutHandler
    
    /// The handler type for processing this command
    var handlerType: HandlerType.Type { LogoutHandler.self }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .logout)
    }
} 
