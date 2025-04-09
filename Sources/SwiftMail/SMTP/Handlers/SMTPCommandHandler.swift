import Foundation
import NIOCore
import Logging

/// Protocol for SMTP command handlers
protocol SMTPCommandHandler: ChannelInboundHandler, Sendable where ResultType: Sendable {
    /// The result type for this handler
    associatedtype ResultType
    
    /// Optional tag for the command (rarely used in SMTP but included for consistency)
    var commandTag: String? { get }
    
    /// The promise that will be fulfilled when the command completes
    var promise: EventLoopPromise<ResultType> { get }
    
    /// Process a response from the server
    /// - Parameter response: The response to process
    /// - Returns: Whether the handler is complete
    func processResponse(_ response: SMTPResponse) -> Bool
    
    /// Required initializer for creating handler instances
    /// - Parameters:
    ///   - commandTag: Optional tag for the command
    ///   - promise: The promise to fulfill when the command completes
    init(commandTag: String?, promise: EventLoopPromise<ResultType>)
}
