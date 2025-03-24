// IMAPMailCommand.swift
// IMAP-specific extensions to the base MailCommand protocol

import Foundation
import NIO


/// IMAP specific command extensions
protocol IMAPMailCommand: MailCommand {
    /// The type of the tagged command
    associatedtype TaggedCommandType
    
    /// Convert this high-level command to a network-level tagged command format
    /// - Parameter tag: The command tag to use
    /// - Returns: The tagged command representation
    func toTaggedCommand(tag: String) -> TaggedCommandType
}

/// Response handler protocol for IMAP commands
protocol IMAPCommandResponseHandler: MailCommandHandler {
    /// The type of response this handler processes
    associatedtype IMAPResponseType
    
    /// Process an IMAP response
    /// - Parameter response: The IMAP response to process
    /// - Returns: Whether the handler is complete
    func processResponse(_ response: IMAPResponseType) -> Bool
} 
