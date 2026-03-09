// MessagePart.swift
// Structure to hold information about a message part

import Foundation
import SwiftTextHTML

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

	/// For message/rfc822 parts: metadata from the embedded message's envelope.
	/// Populated with subject, from, to, cc, date from the IMAP BODYSTRUCTURE envelope.
	/// Other MessageInfo fields (uid, flags, parts, etc.) are defaults.
	public let embeddedMessageInfo: MessageInfo?

	/// Creates a new message part
	/// - Parameters:
	///   - section: The section number (e.g., [1, 2, 3] represents "1.2.3")
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition (e.g., "inline", "attachment")
	///   - encoding: The content transfer encoding (e.g., "base64", "quoted-printable")
	///   - filename: The filename (if any)
	///   - contentId: The content ID
	///   - data: The content data (optional)
	///   - embeddedMessageInfo: Envelope headers for message/rfc822 parts (optional)
	public init(section: Section, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil, embeddedMessageInfo: MessageInfo? = nil) {
		self.section = section
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
		self.embeddedMessageInfo = embeddedMessageInfo
	}

	/// Initialize a new message part with a dot-separated string section number
	/// - Parameters:
	///   - sectionString: The section number as a dot-separated string (e.g., "1.2.3")
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition
	///   - filename: The filename
	///   - contentId: The content ID
	///   - data: The content data (optional)
	public init(sectionString: String, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil, embeddedMessageInfo: MessageInfo? = nil) {
		self.section = Section(sectionString)
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
		self.embeddedMessageInfo = embeddedMessageInfo
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
			
			return "part_\(section.description.replacingOccurrences(of: ".", with: "_")).\(fileExtension)"
		}
	}

	/// The charset declared in the Content-Type header (if present).
	public var declaredCharset: String? {
		let charsetPattern = "charset=([^\\s;\"']+)"
		guard let range = contentType.range(of: charsetPattern, options: .regularExpression) else {
			return nil
		}

		return String(contentType[range])
			.replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive)
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "\"", with: "")
			.replacingOccurrences(of: "'", with: "")
	}
	
	/// The text content of the part
	/// - Returns: The text content, or nil if can't be decoded
	public var textContent: String? {
		guard let transferDecodedData = decodedData() else {
			return nil
		}

		// Decode bytes exactly once, preferring the declared charset.
		if let declaredCharset,
		   let text = String(data: transferDecodedData, encoding: String.encodingFromCharset(declaredCharset)) {
			return text
		}

		// Fallbacks for malformed/unknown charset labels in real-world mail.
		let fallbackEncodings: [String.Encoding] = [.utf8, .windowsCP1252, .isoLatin1, .ascii]
		for fallback in fallbackEncodings {
			if let text = String(data: transferDecodedData, encoding: fallback) {
				return text
			}
		}

		return nil
	}
	
	/// Convert HTML body content to Markdown while preserving original charset bytes.
	///
	/// This passes transfer-decoded bytes and the declared charset through to
	/// `HTMLDocument(data:baseURL:encoding:)` so HTML parsing can decode text correctly.
	///
	/// - Parameter baseURL: Optional base URL for resolving relative links/images.
	/// - Returns: Markdown text for HTML parts, otherwise `nil`.
	public func markdownContent(baseURL: URL? = nil) async -> String? {
		guard contentType.lowercased().hasPrefix("text/html") else {
			return nil
		}

		guard let transferDecodedData = decodedData() else {
			return nil
		}

		let declaredEncoding = declaredCharset.flatMap { stringEncoding(for: $0) }

		do {
			let document = try await HTMLDocument(
				data: transferDecodedData,
				baseURL: baseURL,
				encoding: declaredEncoding
			)
			return document.markdown()
		} catch {
			// Fallback path for unknown/unsupported/malformed charset labels:
			// allow SwiftText to auto-detect by not forcing an encoding.
			do {
				let document = try await HTMLDocument(data: transferDecodedData, baseURL: baseURL, encoding: nil)
				return document.markdown()
			} catch {
				return nil
			}
		}
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
		case section, contentType, disposition, encoding, filename, contentId, data, embeddedMessageInfo
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
		try container.encodeIfPresent(embeddedMessageInfo, forKey: .embeddedMessageInfo)
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
		embeddedMessageInfo = try container.decodeIfPresent(MessageInfo.self, forKey: .embeddedMessageInfo)
	}
}
