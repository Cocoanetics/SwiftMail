import Foundation
import NIOCore
import Logging

/// Handler for the EHLO command, which returns server capabilities
public class EHLOHandler: BaseSMTPHandler<String> {
    /// The logger for this handler
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.EHLOHandler")
    
    /// Handle a successful response by returning the raw response text
    override public func handleSuccess(response: SMTPResponse) {
        logger.debug("Received EHLO response: \(response.message)")
        promise.succeed(response.message)
    }
} 