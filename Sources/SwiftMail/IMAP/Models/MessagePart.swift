// MessagePart.swift
// Structure to hold information about a message part

import Foundation
import SwiftTextHTML

/// Headers extracted from the envelope of an embedded message/rfc822 part.
/// Provides the metadata needed to render forwarded-message-style header blocks.
public struct EmbeddedMessageHeaders: Codable, Sendable {
	public let subject: String?
	public let from: String?
	public let to: String?
	public let cc: String?
	public let date: String?

	public init(subject: String?, from: String?, to: String?, cc: String?, date: String?) {
		self.subject = subject
		self.from = from
		self.to = to
		self.cc = cc
		self.date = date
	}
}

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

	/// For message/rfc822 parts: envelope headers of the embedded message.
	/// Used to render forwarded-message-style header blocks in the body.
	public let embeddedHeaders: EmbeddedMessageHeaders?

	/// Creates a new message part
	/// - Parameters:
	///   - section: The section number (e.g., [1, 2, 3] represents "1.2.3")
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition (e.g., "inline", "attachment")
	///   - encoding: The content transfer encoding (e.g., "base64", "quoted-printable")
	///   - filename: The filename (if any)
	///   - contentId: The content ID
	///   - data: The content data (optional)
	///   - embeddedHeaders: Envelope headers for message/rfc822 parts (optional)
	public init(section: Section, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil, embeddedHeaders: EmbeddedMessageHeaders? = nil) {
		self.section = section
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
		self.embeddedHeaders = embeddedHeaders
	}
	
	/// Initialize a new message part with a dot-separated string section number
	/// - Parameters:
	///   - sectionString: The section number as a dot-separated string (e.g., "1.2.3")
	///   - contentType: The content type (e.g., "text/html", "image/jpeg")
	///   - disposition: The content disposition
	///   - filename: The filename
	///   - contentId: The content ID
	///   - data: The content data (optional)
	public init(sectionString: String, contentType: String, disposition: String? = nil, encoding: String? = nil, filename: String? = nil, contentId: String? = nil, data: Data? = nil, embeddedHeaders: EmbeddedMessageHeaders? = nil) {
		self.section = Section(sectionString)
		self.contentType = contentType
		self.disposition = disposition
		self.encoding = encoding
		self.filename = filename
		self.contentId = contentId
		self.data = data
		self.embeddedHeaders = embeddedHeaders
	}
	
	/// Get a suggested filename for the part
	/// - Returns: A filename based on part information
	public var suggestedFilename: String {
		if let filename = self.filename, !filename.isEmpty {
			// Use the original filename if available
			return filename.sanitizedFileName()
		} else {
			// Create a filename based on section number and content type.
			// Strip parameters (e.g., "; charset=utf-8") before MIME lookup.
			let baseType = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? contentType
			let fileExtension = String.fileExtension(for: baseType) ?? "dat"

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
		case section, contentType, disposition, encoding, filename, contentId, data, embeddedHeaders
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
		try container.encodeIfPresent(embeddedHeaders, forKey: .embeddedHeaders)
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
		embeddedHeaders = try container.decodeIfPresent(EmbeddedMessageHeaders.self, forKey: .embeddedHeaders)
	}
}
