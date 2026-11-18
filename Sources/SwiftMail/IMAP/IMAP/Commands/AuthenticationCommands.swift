// AuthenticationCommands.swift
// Commands related to IMAP authentication

import Foundation
import NIO
import NIOIMAP

/// Command for logging into an IMAP server
struct LoginCommand: IMAPTaggedCommand {
    typealias ResultType = [Capability]
    typealias HandlerType = LoginHandler

    /// The username for authentication
    let username: String

    /// The password for authentication
    let password: String

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
struct LogoutCommand: IMAPTaggedCommand {
    typealias ResultType = Void
    typealias HandlerType = LogoutHandler

    /// LOGOUT ends the session it is sent on; a closed connection has none to end.
    var reopensClosedConnection: Bool { false }

    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    func toTaggedCommand(tag: String) -> TaggedCommand {
        return TaggedCommand(tag: tag, command: .logout)
    }
}
