// MessagePart+BodyStructure.swift
// Extension that adds an initializer to Array<MessagePart> from BodyStructure

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension Array where Element == MessagePart {
    /**
     Initialize an array of message parts from a BodyStructure
     
     This creates a flat array of leaf message parts without fetching any content.
     
     - Parameter structure: The body structure to process
     - Parameter sectionPath: Path representing the section numbering, default is empty
     */
    public init(_ structure: BodyStructure, sectionPath: [Int] = []) {
        // Initialize with empty array
        self = []
        
        switch structure {
        case .singlepart(let part):
            // Determine the part number as Section type for IMAP
            let section = Section(sectionPath.isEmpty ? [1] : sectionPath)
            
            // Extract content type and other metadata
            var contentType = ""
            
            switch part.kind {
                case .basic(let mediaType):
                    contentType = "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
                case .text(let text):
                    contentType = "text/\(String(text.mediaSubtype))"
                case .message(let message):
                    contentType = "message/\(String(message.message))"
            }
            
            // Add charset parameter if present
            if let charset = part.fields.parameters.first(where: { $0.key.lowercased() == "charset" })?.value {
                contentType += "; charset=\(charset)"
            }
            
            // Extract disposition and filename if available
            var disposition: String? = nil
            var filename: String? = nil
            let encoding: String? = part.fields.encoding?.debugDescription
            
            // Check Content-Type parameters for filename or name first
            for (key, value) in part.fields.parameters {
                let lowerKey = key.lowercased()
                if (lowerKey == "filename" || lowerKey == "name"), !value.isEmpty {
                    filename = value
                    break
                }
            }
            
            // Then check Content-Disposition (which overrides Content-Type filename if present)
            if let ext = part.extension, let dispAndLang = ext.dispositionAndLanguage {
                if let disp = dispAndLang.disposition {
                    // Extract just the disposition kind (attachment, inline, etc.)
                    disposition = String(disp.kind.rawValue)
                    
                    for (key, value) in disp.parameters {
                        if key.lowercased() == "filename" && !value.isEmpty {
                            filename = value
                            break
                        }
                    }
                }
            }
            
            // Fallback: If still no filename and we have a content ID, use it
            if filename == nil, let contentId = part.fields.id {
                let idString = String(contentId)
                if !idString.isEmpty {
                    // Remove angle brackets if present (common in Content-ID)
                    let cleanId = idString.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    if !cleanId.isEmpty {
                        // Use the content ID directly as the filename
                        filename = cleanId
                    }
                }
            }

            // Decode any MIME-encoded filename
            if let name = filename {
                let decoded = name.decodeMIMEHeader()
                if !decoded.isEmpty {
                    filename = decoded
                }
            }

            // Set content ID if available
            let contentId: String? = part.fields.id.map {
                let str = String($0)
                return str.isEmpty ? nil : str
            } ?? nil
            
            // Create a message part with empty data
            let messagePart = MessagePart(
                section: section,
                contentType: contentType,
                disposition: disposition,
                encoding: encoding?.isEmpty == true ? nil : encoding,
                filename: filename,
                contentId: contentId,
                data: nil
            )
            
            // Append to our result
            self.append(messagePart)
            
        case .multipart(let multipart):
            // For multipart messages, process each child part and collect results
            for (index, childPart) in multipart.parts.enumerated() {
                // Create a new section path array by appending the current index + 1
                let childSectionPath = sectionPath.isEmpty ? [index + 1] : sectionPath + [index + 1]
                
                // Recursively process child parts
                let childParts = Array<MessagePart>(childPart, sectionPath: childSectionPath)
                
                // Append all child parts to our result
                self.append(contentsOf: childParts)
            }
        }
    }
} 
