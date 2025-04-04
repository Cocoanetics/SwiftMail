// MessagePart.swift
// Structure to hold information about a message part

import Foundation

/// A part of an email message
public struct MessagePart: Sendable {
	/// The section number (e.g., [1, 2, 3] represents "1.2.3")
	public let section: Section
	
	/// The content type of the part (e.g., "text/html", "image/jpeg")
	public let contentType: String
	
	/// The content disposition (e.g., "inline", "attachment")
	public let disposition: String?
	
	/// The content transfer encoding (e.g., "base64", "quoted-printable")
	public let encoding: String?
	
	/// The filename of the part (if any)
	public let filename: String?
	
	/// The content ID of the part (if any)
	public let contentId: String?
	
	/// The content data (if any)
	public var data: Data?
	
	/// Creates a new message part
	/// - Parameters:
	///   - section: The section number (e.g., [1, 2, 3] represents "1.2.3")
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition (e.g., "inline", "attachment")
	///   - encoding: The content transfer encoding (e.g., "base64", "quoted-printable")
	///   - filename: The filename (if any)
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
		self.section = Section(sectionString)
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
	}
	
	/// Get a suggested filename for the part
	/// - Returns: A filename based on part information
	public var suggestedFilename: String {
		if let filename = self.filename, !filename.isEmpty {
			// Use the original filename if available
			return filename.sanitizedFileName()
		} else {
			// Create a filename based on section number and content type
			let fileExtension = String.fileExtension(for: contentType) ?? "dat"
			
			print(contentId)
			return "part_\(section.description.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
		}
	}
	
	/// Get the text content of the part if it's a text part
	/// - Returns: The text content, or nil if not a text part or can't be decoded
	public func textContent() -> String? {
		guard contentType.lowercased().hasPrefix("text/"), let data = data, data.isTextContent() else {
			return nil
		}
		
		let decodedData = data.decoded(for: self)
		return String(data: decodedData, encoding: .utf8)
	}
	
	/// Decode the part content using appropriate decoding based on content type and encoding
	/// - Returns: The decoded data, or nil if no data is available
	public func decodedData() -> Data? {
		guard let data = data else {
			return nil
		}
		
		return data.decoded(for: self)
	}
}

// MARK: - Codable Implementation
extension MessagePart: Codable {
	private enum CodingKeys: String, CodingKey {
		case section, contentType, disposition, encoding, filename, contentId, data
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		
		try container.encode(section, forKey: .section)
		try container.encode(contentType, forKey: .contentType)
		try container.encodeIfPresent(disposition, forKey: .disposition)
		try container.encodeIfPresent(encoding, forKey: .encoding)
		try container.encodeIfPresent(filename, forKey: .filename)
		try container.encodeIfPresent(contentId, forKey: .contentId)
		try container.encodeIfPresent(data, forKey: .data)
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		
		section = try container.decode(Section.self, forKey: .section)
		contentType = try container.decode(String.self, forKey: .contentType)
		disposition = try container.decodeIfPresent(String.self, forKey: .disposition)
		encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
		filename = try container.decodeIfPresent(String.self, forKey: .filename)
		contentId = try container.decodeIfPresent(String.self, forKey: .contentId)
		data = try container.decodeIfPresent(Data.self, forKey: .data)
	}
}
