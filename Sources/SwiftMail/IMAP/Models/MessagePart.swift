// MessagePart.swift
// Structure to hold information about a message part

import Foundation

/// Structure to hold information about a message part
public struct MessagePart: Codable, Sendable {
	/// The part number (e.g., "1", "1.1", "2", etc.)
	public let partNumber: String
	
	/// The content type of the part
	public let contentType: String
	
	/// The content subtype of the part
	public let contentSubtype: String
	
	/// The content disposition of the part (e.g., "attachment", "inline")
	public let disposition: String?
	
	/// How the content is encoded
	public let encoding: String?
	
	/// The filename of the part (if available)
	public let filename: String?
	
	/// The content ID of the part (if available)
	public let contentId: String?
	
	/// The content of the part
	public let data: Data
	
	/// The size of the part in bytes
	public var size: Int {
		return data.count
	}
	
	/// Initialize a new message part
	/// - Parameters:
	///   - partNumber: The part number
	///   - contentType: The content type
	///   - contentSubtype: The content subtype
	///   - disposition: The content disposition
	///   - filename: The filename
	///   - contentId: The content ID
	///   - data: The content data
	public init(partNumber: String, contentType: String, contentSubtype: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data) {
		self.partNumber = partNumber
		self.contentType = contentType
		self.contentSubtype = contentSubtype
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
	}
    
    /// Get a suggested filename for the part
    /// - Returns: A filename based on part information
    public func suggestedFilename() -> String {
        if let filename = self.filename, !filename.isEmpty {
            // Use the original filename if available
            return filename.sanitizedFileName()
        } else {
            // Create a filename based on part number and content type
            let mimeType = "\(contentType)/\(contentSubtype)"
            let fileExtension = String.fileExtension(for: mimeType) ?? "dat"
            return "part_\(partNumber.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
        }
    }
    
    /// Get the text content of the part if it's a text part
    /// - Returns: The text content, or nil if not a text part or can't be decoded
    public func textContent() -> String? {
        guard contentType.lowercased() == "text" || data.isTextContent() else {
            return nil
        }
        
        return String(data: data, encoding: String.Encoding.utf8)
    }
    
    /// Decode the part content if it's quoted-printable encoded
    /// - Returns: The decoded data, or the original data if not encoded or can't be decoded
    public func decodedContent() -> Data {
        guard contentType.lowercased() == "text", 
              let textContent = String(data: data, encoding: String.Encoding.utf8) else {
            return data
        }
        
        // Check for Content-Transfer-Encoding header in the part data
        let isQuotedPrintable = textContent.contains("Content-Transfer-Encoding: quoted-printable") ||
                               textContent.contains("Content-Transfer-Encoding:quoted-printable") ||
                               textContent.contains("=3D") || // Common quoted-printable pattern
                               textContent.contains("=\r\n") || // Soft line break
                               textContent.contains("=\n")    // Soft line break
        
        if isQuotedPrintable {
            // Extract charset from Content-Type header if available
            var charset = "utf-8" // Default charset
            let contentTypePattern = "Content-Type:.*?charset=([^\\s;\"']+)"
            if let range = textContent.range(of: contentTypePattern, options: .regularExpression, range: nil, locale: nil),
               let charsetRange = textContent[range].range(of: "charset=([^\\s;\"']+)", options: .regularExpression) {
                charset = String(textContent[charsetRange].replacingOccurrences(of: "charset=", with: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
            }
            
            // Use the extracted charset for decoding
            let encoding = String.encodingFromCharset(charset)
            if let decodedContent = textContent.decodeQuotedPrintable(encoding: encoding),
               let decodedData = decodedContent.data(using: String.Encoding.utf8) {
                return decodedData
            } else {
                // Fallback to the String extension if specific charset decoding fails
                let decodedContent = textContent.decodeQuotedPrintableContent()
                if let decodedData = decodedContent.data(using: String.Encoding.utf8) {
                    return decodedData
                }
            }
        }
        
        return data
    }
    
    /// Get a preview of the part content
    /// - Parameter maxLength: The maximum length of the preview
    /// - Returns: A string preview of the content
    public func contentPreview(maxLength: Int = 500) -> String {
        let decodedData = decodedContent()
        return decodedData.preview(maxLength: maxLength)
    }
}
