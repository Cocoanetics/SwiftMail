import Foundation
import NIOCore

/**
 Command to send email content data
 */
public struct SendContentCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = SendContentHandler
    
    /// The email content to send
    private let content: String
	
	/// Default timeout in seconds
	public let timeoutSeconds: Int = 10
    
    /**
     Initialize a new SendContent command
     - Parameter content: The email content to send
     */
    public init(content: String) {
        self.content = content
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        // Add terminating period on a line by itself to indicate end of content
        return content + "\r\n."
    }
    
    /**
     Validate that the content is not empty
     */
    public func validate() throws {
        guard !content.isEmpty else {
            throw SMTPError.sendFailed("Email content cannot be empty")
        }
    }
} 
