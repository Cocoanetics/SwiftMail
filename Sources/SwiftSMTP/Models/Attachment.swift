import Foundation

/**
 A struct representing an email attachment
 */
public struct Attachment {
    /** The filename of the attachment */
    public let filename: String
    
    /** The MIME type of the attachment */
    public let mimeType: String
    
    /** The data of the attachment */
    public let data: Data
    
    /**
     Initialize a new attachment
     - Parameters:
     - filename: The filename of the attachment
     - mimeType: The MIME type of the attachment
     - data: The data of the attachment
     */
    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
} 