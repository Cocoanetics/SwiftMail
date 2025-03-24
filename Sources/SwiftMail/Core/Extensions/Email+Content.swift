import Foundation

extension Email {
    public func constructContent(use8BitMIME: Bool = false) -> String {
        var content = ""

        content += "From: \(self.sender)\r\n"

        if !self.recipients.isEmpty {
            content += "To: \(self.recipients.map { $0.description }.joined(separator: ", "))\r\n"
        }

        if !self.ccRecipients.isEmpty {
            content += "Cc: \(self.ccRecipients.map { $0.description }.joined(separator: ", "))\r\n"
        }

        content += "Subject: \(self.subject)\r\n"
        content += "MIME-Version: 1.0\r\n"

        let mainBoundary = "SwiftSMTP-Boundary-\(UUID().uuidString)"
        let altBoundary = "SwiftSMTP-Alt-Boundary-\(UUID().uuidString)"
        let relatedBoundary = "SwiftSMTP-Related-Boundary-\(UUID().uuidString)"

        let textEncoding: String
        let textBody: String
        let htmlBody: String?

        if use8BitMIME && self.textBody.isSafe8BitContent() &&
           (self.htmlBody == nil || self.htmlBody!.isSafe8BitContent()) {
            textEncoding = "8bit"
            textBody = self.textBody
            htmlBody = self.htmlBody
        } else {
            textEncoding = "quoted-printable"
            textBody = self.textBody.quotedPrintableEncoded()
            htmlBody = self.htmlBody?.quotedPrintableEncoded()
        }

        let hasHtmlBody = self.htmlBody != nil
        let hasInlineAttachments = !self.inlineAttachments.isEmpty
        let hasRegularAttachments = !self.regularAttachments.isEmpty

        // Determine the structure based on what we have
        if hasRegularAttachments {
            // If we have regular attachments, use multipart/mixed as the top level
            content += "Content-Type: multipart/mixed; boundary=\"\(mainBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // Start with the text/html part
            if hasHtmlBody {
                content += "--\(mainBoundary)\r\n"
                
                if hasInlineAttachments {
                    // If we have inline attachments, use multipart/related for HTML and inline attachments
                    content += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
                    
                    // First add the multipart/alternative part
                    content += "--\(relatedBoundary)\r\n"
                    content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
                    
                    // Add text part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/plain; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
                    content += "\(textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
                    content += "\(htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                    
                    // Add inline attachments
                    for attachment in self.inlineAttachments {
                        content += "--\(relatedBoundary)\r\n"
                        content += "Content-Type: \(attachment.mimeType)"
                        content += "; name=\"\(attachment.filename)\"\r\n"
                        content += "Content-Transfer-Encoding: base64\r\n"
                        
                        if let contentID = attachment.contentID {
                            content += "Content-ID: <\(contentID)>\r\n"
                        }
                        
                        content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
                        
                        // Encode attachment data as base64
                        let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                        content += "\(base64Data)\r\n\r\n"
                    }
                    
                    // End related boundary
                    content += "--\(relatedBoundary)--\r\n\r\n"
                } else {
                    // No inline attachments, just use multipart/alternative
                    content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
                    
                    // Add text part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/plain; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
                    content += "\(textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
                    content += "\(htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                }
            } else {
                // Just text, no HTML
                content += "--\(mainBoundary)\r\n"
                content += "Content-Type: text/plain; charset=UTF-8\r\n"
                content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
                content += "\(textBody)\r\n\r\n"
            }
            
            // Add regular attachments
            for attachment in self.regularAttachments {
                content += "--\(mainBoundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)\r\n"
                content += "Content-Transfer-Encoding: base64\r\n"
                content += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n\r\n"
                
                // Encode attachment data as base64
                let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                content += "\(base64Data)\r\n\r\n"
            }
            
            // End main boundary
            content += "--\(mainBoundary)--\r\n"
        } else if hasHtmlBody && hasInlineAttachments {
            // HTML with inline attachments but no regular attachments - use multipart/related
            content += "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // First add the multipart/alternative part
            content += "--\(relatedBoundary)\r\n"
            content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            
            // Add text part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
            content += "\(textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
            content += "\(htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n\r\n"
            
            // Add inline attachments
            for attachment in self.inlineAttachments {
                content += "--\(relatedBoundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)"
                content += "; name=\"\(attachment.filename)\"\r\n"
                content += "Content-Transfer-Encoding: base64\r\n"
                
                if let contentID = attachment.contentID {
                    content += "Content-ID: <\(contentID)>\r\n"
                }
                
                content += "Content-Disposition: inline; filename=\"\(attachment.filename)\"\r\n\r\n"
                
                // Encode attachment data as base64
                let base64Data = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn])
                content += "\(base64Data)\r\n\r\n"
            }
            
            // End related boundary
            content += "--\(relatedBoundary)--\r\n"
        } else if hasHtmlBody {
            // Only HTML, no attachments - use multipart/alternative
            content += "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n"
            content += "This is a multi-part message in MIME format.\r\n\r\n"
            
            // Add text part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
            content += "\(textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
            content += "\(htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n"
        } else {
            // Simple text email
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: \(textEncoding)\r\n\r\n"
            content += textBody
        }
        
        return content
    }
} 