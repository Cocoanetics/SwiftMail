import Foundation
import NIOCore
import Logging

/// Handler for the EHLO command, which returns server capabilities
class EHLOHandler: BaseSMTPHandler<String>, @unchecked Sendable {
    
    /// Handle a successful response by returning the raw response text
    override func handleSuccess(response: SMTPResponse) {
        promise.succeed(response.message)
    }
} 
