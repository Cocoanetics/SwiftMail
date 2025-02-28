// MailboxCommands.swift
// Commands related to IMAP mailboxes

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO

/// Command for selecting a mailbox
public struct SelectMailboxCommand: IMAPCommand {
    public typealias ResultType = MailboxInfo
    public typealias HandlerType = SelectHandler
    
    /// The name of the mailbox to select
    public let mailboxName: String
    
    /// The handler type for processing this command
    public var handlerType: HandlerType.Type { SelectHandler.self }
    
    /// Initialize a new select mailbox command
    /// - Parameter mailboxName: The name of the mailbox to select
    public init(mailboxName: String) {
        self.mailboxName = mailboxName
    }
    
    /// Convert to an IMAP tagged command
    /// - Parameter tag: The command tag
    /// - Returns: A TaggedCommand ready to be sent to the server
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let mailbox = MailboxName(Array(mailboxName.utf8))
        return TaggedCommand(tag: tag, command: .select(mailbox, []))
    }
} 