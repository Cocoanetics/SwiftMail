import Foundation
import NIOCore
import Logging

/// Handler for the EHLO command, which returns server capabilities
public class EHLOHandler: BaseSMTPHandler<[String]> {
    /// Handle a successful response by parsing capabilities
    override public func handleSuccess(response: SMTPResponse) {
        // Parse capabilities from the EHLO response
        let capabilities = parseCapabilities(from: response.message)
        promise.succeed(capabilities)
    }
    
    /// Parse server capabilities from EHLO response
    /// - Parameter response: The EHLO response message
    /// - Returns: Array of capability strings
    private func parseCapabilities(from response: String) -> [String] {
        var capabilities: [String] = []
        
        // Split the response into lines
        let lines = response.split(separator: "\n")
        
        // Process each line (skip the first line which is the greeting)
        for line in lines.dropFirst() {
            // Extract the capability (remove the response code prefix if present)
            let capabilityLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if capabilityLine.count > 4 && capabilityLine.prefix(4).allSatisfy({ $0.isNumber || $0 == "-" }) {
                // This is a line with a response code prefix (e.g., "250-SIZE 20480000")
                let capability = String(capabilityLine.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                
                // Extract the base capability (before any parameters)
                let baseCapability = capability.split(separator: " ").first.map(String.init) ?? capability
                capabilities.append(baseCapability)
            }
        }
        
        return capabilities
    }
} 