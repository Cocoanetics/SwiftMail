// SMTPMailCommand.swift
// SMTP-specific extensions to the base MailCommand protocol

import Foundation
import NIO
import SwiftMailCore

/// SMTP specific command extensions
public protocol SMTPMailCommand: MailCommand {
    /// Convert this command to a string that can be sent to the SMTP server
    func toCommandString() -> String
    
    /// Convert this command to a string that can be sent to the SMTP server with a hostname
    /// - Parameter localHostname: The local hostname to use for commands that require it (e.g., EHLO)
    /// - Returns: The command string
    func toString(localHostname: String) -> String
}

/// Default implementations for SMTP commands
public extension SMTPMailCommand {
    /// Default implementation that defers to toString
    func toCommandString() -> String {
        fatalError("Must be implemented by subclass - either toCommandString() or toString(localHostname:)")
    }
    
    /// Default implementation returns the basic command string
    func toString(localHostname: String) -> String {
        return toCommandString()
    }
}

/// Response handler protocol for SMTP commands
public protocol SMTPCommandResponseHandler: MailCommandHandler {
    /// The type of response this handler processes
    associatedtype SMTPResponseType
    
    /// Process an SMTP response
    /// - Parameter response: The SMTP response to process
    /// - Returns: Whether the handler is complete
    func processResponse(_ response: SMTPResponseType) -> Bool
} 