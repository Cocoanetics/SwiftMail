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
     Applies RFC 5321 §4.5.2 dot-stuffing and appends the terminating sequence.
     */
    func toCommandData() -> Data {
        let stuffed = Self.dotStuff(contentData)
        var result = stuffed
        // Add terminating CRLF.CRLF (the DATA terminator)
        result.append(contentsOf: [0x0D, 0x0A, 0x2E]) // \r\n.
        return result
    }

    /**
     Convert the command to a string that can be sent to the server
     - Note: Prefer `toCommandData()` for raw byte handling.
     */
	func toCommandString() -> String {
        let stuffed = Self.dotStuff(contentData)
        let contentString = String(decoding: stuffed, as: UTF8.self)
        return contentString + "\r\n."
    }

    /// RFC 5321 §4.5.2 — Any line in the message body that starts with a period
    /// must have an additional period prepended ("dot-stuffing"). The receiving
    /// server strips the extra dot. Without this, a leading dot can be mistaken
    /// for the end-of-data indicator, truncating the message.
    static func dotStuff(_ data: Data) -> Data {
        let cr: UInt8 = 0x0D
        let lf: UInt8 = 0x0A
        let dot: UInt8 = 0x2E

        var result = Data(capacity: data.count + data.count / 40) // small over-allocation
        var atLineStart = true

        for byte in data {
            if atLineStart && byte == dot {
                result.append(dot) // extra dot
            }
            result.append(byte)
            if byte == lf {
                atLineStart = true
            } else if byte != cr {
                atLineStart = false
            }
            // CR keeps atLineStart unchanged (waiting for LF)
        }

        return result
    }
} 
