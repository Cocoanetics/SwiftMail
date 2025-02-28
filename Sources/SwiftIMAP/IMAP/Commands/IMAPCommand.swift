// IMAPCommand.swift
// Base protocol for all IMAP commands

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// A protocol for all IMAP commands that know their handler type
public protocol IMAPCommand {
    /// The result type this command produces
    associatedtype ResultType
    
    /// The handler type used to process this command
    associatedtype HandlerType: IMAPCommandHandler where HandlerType.ResultType == ResultType
    
    /// Returns the handler type for processing this command
    var handlerType: HandlerType.Type { get }
    
    /// Convert this high-level command to a NIO TaggedCommand
    func toTaggedCommand(tag: String) -> TaggedCommand
    
    /// Default timeout for this command type
    var timeoutSeconds: Int { get }
    
    /// Check if the command is valid before execution
    func validate() throws
}

// Provide reasonable defaults
public extension IMAPCommand {
    var timeoutSeconds: Int { return 5 }
    
    func validate() throws {
        // Default implementation does no validation
    }
} 