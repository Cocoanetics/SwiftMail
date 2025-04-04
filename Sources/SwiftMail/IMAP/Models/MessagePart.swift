// MessagePart.swift
// Structure to hold information about a message part

import Foundation

/// Structure to hold information about a message part
public struct MessagePart: Sendable {
	/// The section number (e.g., [1, 2, 3] represents "1.2.3")
	public let section: Section
	
	/// The content type of the part (e.g., "text/html", "image/jpeg")
	public let contentType: String
	
	/// The content disposition of the part (e.g., "attachment", "inline")
	public let disposition: String?
	
	/// How the content is encoded
	public let encoding: String?
	
	/// The filename of the part (if available)
	public let filename: String?
	
	/// The content ID of the part (if available)
	public let contentId: String?
	
	/// The content of the part (optional - only available when fetched)
	public let data: Data?
	
	/// Initialize a new message part
	/// - Parameters:
	///   - section: The section number as a section array
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition
	///   - filename: The filename
	///   - contentId: The content ID
	///   - data: The content data (optional)
	public init(section: Section, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil) {
		self.section = section
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
	}
    
    /// Initialize a new message part with a dot-separated string section number
    /// - Parameters:
    ///   - sectionString: The section number as a dot-separated string (e.g., "1.2.3")
    ///   - contentType: The content type (e.g., "text/html", "image/jpeg")
    ///   - disposition: The content disposition
    ///   - filename: The filename
    ///   - contentId: The content ID
    ///   - data: The content data (optional)
    public init(sectionString: String, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil) {
        // Convert dot-separated string to Section array
        if sectionString.isEmpty {
            self.section = [1] // Default to first part if empty
        } else {
            self.section = sectionString.split(separator: ".").compactMap { Int($0) }
        }
        
        self.contentType = contentType
        self.disposition = disposition
        self.encoding = encoding
        self.filename = filename
        self.contentId = contentId
        self.data = data
    }
    
    /// Get the section number as a dot-separated string
    /// - Returns: The section number as a dot-separated string (e.g., "1.2.3")
    public var sectionString: String {
        return section.map { String($0) }.joined(separator: ".")
    }
    
    /// Get a suggested filename for the part
    /// - Returns: A filename based on part information
    public func suggestedFilename() -> String {
        if let filename = self.filename, !filename.isEmpty {
            // Use the original filename if available
            return filename.sanitizedFileName()
        } else {
            // Create a filename based on section number and content type
            let fileExtension = String.fileExtension(for: contentType) ?? "dat"
            return "part_\(sectionString.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
        }
    }
    
    /// Get the text content of the part if it's a text part
    /// - Returns: The text content, or nil if not a text part or can't be decoded
    public func textContent() -> String? {
        guard contentType.lowercased().hasPrefix("text/"), let data = data, data.isTextContent() else {
            return nil
        }
        
        return String(data: data, encoding: String.Encoding.utf8)
    }
    
    /// Decode the part content if it's quoted-printable encoded
    /// - Returns: The decoded data, or the original data if not encoded or can't be decoded
    public func decodedContent() -> Data? {
        guard let data = data else {
            return nil
        }
        
        guard contentType.lowercased().hasPrefix("text/"), 
              let textContent = String(data: data, encoding: String.Encoding.utf8) else {
			
			if encoding?.lowercased() == "base64",
			   let base64String = String(data: data, encoding: .utf8) {
				let normalized = base64String.replacingOccurrences(of: "\r", with: "")
											   .replacingOccurrences(of: "\n", with: "")
				
				if let decoded = Data(base64Encoded: normalized)
				{
					return decoded
				}
			}
			
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
        guard let decodedData = decodedContent() else {
            return "[Content not available]"
        }
        return decodedData.preview(maxLength: maxLength)
    }
}

// MARK: - Codable Implementation
extension MessagePart: Codable {
    private enum CodingKeys: String, CodingKey {
        case section, contentType, disposition, encoding, filename, contentId, data
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Encode section as a dot-separated string
        try container.encode(sectionString, forKey: .section)
        
        // Encode other properties normally
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(disposition, forKey: .disposition)
        try container.encodeIfPresent(encoding, forKey: .encoding)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(contentId, forKey: .contentId)
        try container.encodeIfPresent(data, forKey: .data)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode section from dot-separated string
        let sectionString = try container.decode(String.self, forKey: .section)
        let sectionNumbers = sectionString.split(separator: ".").compactMap { Int($0) }
        section = sectionNumbers.isEmpty ? [1] : sectionNumbers
        
        // Decode other properties normally
        contentType = try container.decode(String.self, forKey: .contentType)
        disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        contentId = try container.decodeIfPresent(String.self, forKey: .contentId)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
    }
    
    // For backward compatibility with older versions
    private enum LegacyCodingKeys: String, CodingKey {
        case section, contentType, contentSubtype, disposition, encoding, filename, contentId, data
    }
    
    // Additional initializer to handle decoding from the old format
    public init(legacyDecoder decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LegacyCodingKeys.self)
        
        // Decode section from dot-separated string
        let sectionString = try container.decode(String.self, forKey: .section)
        let sectionNumbers = sectionString.split(separator: ".").compactMap { Int($0) }
        section = sectionNumbers.isEmpty ? [1] : sectionNumbers
        
        // Combine the old separate contentType and contentSubtype
        let type = try container.decode(String.self, forKey: .contentType)
        let subtype = try container.decode(String.self, forKey: .contentSubtype)
        contentType = "\(type)/\(subtype)"
        
        // Decode other properties normally
        disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        contentId = try container.decodeIfPresent(String.self, forKey: .contentId)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
    }
}
