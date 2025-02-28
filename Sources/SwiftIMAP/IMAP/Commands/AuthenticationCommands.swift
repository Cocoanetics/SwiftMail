// AuthenticationCommands.swift
// Commands related to IMAP authentication

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Command for logging into an IMAP server
public struct LoginCommand: IMAPCommand {
    public typealias ResultType = [Capability]
    public typealias HandlerType = LoginHandler
    
    /// The username for authentication
    public let username: String
    
    /// The password for authentication
    public let password: String
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { LoginHandler.self }
    
    /// Initialize a new login command
    /// - Parameters:
    ///   - username: The username for authentication
    ///   - password: The password for authentication
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .login(
            username: username,
            password: password
        ))
    }
}

/// Command for logging out of an IMAP server
public struct LogoutCommand: IMAPCommand {
    public typealias ResultType = Void
    public typealias HandlerType = LogoutHandler
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { LogoutHandler.self }
    
    /// Initialize a new logout command
    public init() {}
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .logout)
    }
} 