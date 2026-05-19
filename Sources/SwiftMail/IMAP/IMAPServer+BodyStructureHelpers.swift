import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Body Structure Helpers

extension IMAPServer {
    /**
     Process a body structure recursively to fetch all parts
     - Parameters:
     - structure: The body structure to process
     - section: The section to process
     - identifier: The message identifier (SequenceNumber or UID)
     - Returns: An array of message parts
     - Throws: An error if the fetch operation fails
     */
    func recursivelyFetchParts<T: MessageIdentifier>(
        _ structure: BodyStructure,
        section: Section,
        identifier: T
    ) async throws -> [MessagePart] {
        switch structure {
            case .singlepart(let part):
                return [try await fetchSinglepart(part, section: section, identifier: identifier)]

            case .multipart(let multipart):
                return try await fetchMultipart(multipart, section: section, identifier: identifier)
        }
    }

    /// Fetch and convert a singlepart body structure.
    private func fetchSinglepart<T: MessageIdentifier>(
        _ part: BodyStructure.Singlepart,
        section: Section,
        identifier: T
    ) async throws -> MessagePart {
        // Fetch the part content
        let partData = try await fetchPart(section: section, of: identifier)

        let contentType = singlepartContentType(part)
        let (disposition, filename) = singlepartDispositionAndFilename(part)
        let encoding: String? = part.fields.encoding?.debugDescription
        let contentId = part.fields.id

        return MessagePart(
            section: section,
            contentType: contentType,
            disposition: disposition,
            encoding: encoding,
            filename: filename,
            contentId: contentId,
            data: partData
        )
    }

    /// Recursively fetch each part of a multipart body structure.
    private func fetchMultipart<T: MessageIdentifier>(
        _ multipart: BodyStructure.Multipart,
        section: Section,
        identifier: T
    ) async throws -> [MessagePart] {
        var allParts: [MessagePart] = []

        for (index, childPart) in multipart.parts.enumerated() {
            // Create a new section by appending the current index + 1
            let childSection = Section(section.components + [index + 1])
            let childParts = try await recursivelyFetchParts(
                childPart, section: childSection, identifier: identifier
            )
            allParts.append(contentsOf: childParts)
        }

        return allParts
    }

    /// Build the `Content-Type` string for a singlepart structure.
    private func singlepartContentType(_ part: BodyStructure.Singlepart) -> String {
        var contentType: String
        switch part.kind {
            case .basic(let mediaType):
                contentType = "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
            case .text(let text):
                contentType = "text/\(String(text.mediaSubtype))"
            case .message(let message):
                contentType = "message/\(String(message.message))"
        }

        if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
            contentType += "; charset=\(charset)"
        }

        return contentType
    }

    /// Extract disposition + filename from a singlepart structure's extension data.
    private func singlepartDispositionAndFilename(
        _ part: BodyStructure.Singlepart
    ) -> (disposition: String?, filename: String?) {
        var disposition: String?
        var filename: String?

        if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage, let disp = dispAndLang.disposition {
            disposition = String(describing: disp)

            for (key, value) in disp.parameters where key.lowercased() == "filename" {
                filename = value
            }
        }

        return (disposition, filename)
    }
}
