// StartTLSCommand.swift
// Common implementation of StartTLS command for both IMAP and SMTP

import Foundation
import NIO

/**
 Base command to initiate TLS/SSL encryption on a connection
 This can be used by both IMAP and SMTP implementations
 */
public struct StartTLSCommand: MailCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = BaseStartTLSHandler<Any>
    
    /// Default timeout in seconds
    public let timeoutSeconds: Int = 10
    
    /**
     Initialize a new STARTTLS command
     */
    public init() {
        // No parameters needed for STARTTLS
    }
    
    /**
     Validation is not required for STARTTLS command
     */
    public func validate() throws {
        // No validation needed for STARTTLS command
    }
}

/**
 SMTP-specific implementation of StartTLS command
 */
extension StartTLSCommand: SMTPMailCommand {
    /**
     Convert the command to a string that can be sent to the SMTP server
     */
    public func toCommandString() -> String {
        return "STARTTLS"
    }
}

/**
 Base handler for StartTLS commands
 */
open class BaseStartTLSHandler<ResponseType>: BaseMailCommandHandler<Bool> {
    /**
     Handle successful response - Override in protocol-specific implementations
     */
    open func handleSuccess(response: ResponseType) {
        handleSuccess(result: true)
    }
    
    /**
     Handle error response - Override in protocol-specific implementations
     */
    open func handleError(response: ResponseType) {
        handleError(error: MailError.commandFailed("STARTTLS failed"))
    }
    
    /**
     Default implementation for unwrapping inbound data
     Must be overridden by subclasses with specific response types
     */
    open override func unwrapInboundIn(_ data: NIOAny) -> Any {
        fatalError("Must be implemented by protocol-specific subclass")
    }
}