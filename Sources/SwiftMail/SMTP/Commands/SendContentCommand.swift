import Foundation
import NIOCore


/**
 Command to send email content data
 */
struct SendContentCommand: SMTPCommand {
    /// The result type is Void since we rely on error throwing for failure cases
	typealias ResultType = Void
    
    /// The handler type that will process responses for this command
	typealias HandlerType = SendContentHandler
    
    /// The fully constructed MIME message content to send (as raw bytes)
    private let contentData: Data
	
	/// Default timeout in seconds
	let timeoutSeconds: Int = 10
    
    /**
     Initialize a new SendContent command with raw data
     - Parameters:
        - data: The fully constructed MIME message content as raw bytes
     */
    init(data: Data) {
        self.contentData = data
    }
    
    /**
     Convert the command to raw bytes that can be sent to the server.
     Appends CRLF and the terminating period.
     */
    func toCommandData() -> Data {
        var result = contentData
        // Add terminating CRLF.CRLF (the DATA terminator)
        result.append(contentsOf: [0x0D, 0x0A, 0x2E]) // \r\n.
        return result
    }
    
    /**
     Convert the command to a string that can be sent to the server
     - Note: Prefer `toCommandData()` for raw byte handling.
     */
	func toCommandString() -> String {
        // Decode as UTF-8 (lossy for non-UTF-8 content)
        let contentString = String(decoding: contentData, as: UTF8.self)
        return contentString + "\r\n."
    }
} 
