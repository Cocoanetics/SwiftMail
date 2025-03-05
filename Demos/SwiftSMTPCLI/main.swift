// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftSMTP
import os
import Logging
import SwiftDotenv
import UniformTypeIdentifiers

// Set default log level to info - will only show important logs
// Per the cursor rules: Use OS_LOG_DISABLE=1 to see log output as needed
LoggingSystem.bootstrap { label in
    // Create an OSLog-based logger
    let category = label.split(separator: ".").last?.description ?? "default"
    let osLogger = OSLog(subsystem: "com.cocoanetics.SwiftSMTPCLI", category: category)
    
    // Set log level to info by default (or trace if SWIFT_LOG_LEVEL is set to trace)
    var handler = OSLogHandler(label: label, log: osLogger)

	// Check if we need verbose logging
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        handler.logLevel = .trace
    } else {
        handler.logLevel = .info
    }
    
    return handler
}

// Create a logger for the main application using Swift Logging
let logger = Logger(label: "com.cocoanetics.SwiftSMTPCLI.Main")

print("📧 SwiftSMTPCLI - Email Sending Test")

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure()
    logger.info("Environment configuration loaded successfully")
    print("Environment configuration loaded successfully")
    
    // Access SMTP credentials using dynamic member lookup with case pattern matching
    guard case let .string(host) = Dotenv["SMTP_HOST"] else {
        logger.error("SMTP_HOST not found in .env file")
        exit(1)
    }
    
    guard case let .integer(port) = Dotenv["SMTP_PORT"] else {
        logger.error("SMTP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    guard case let .string(username) = Dotenv["SMTP_USERNAME"] else {
        logger.error("SMTP_USERNAME not found in .env file")
        exit(1)
    }
    
    guard case let .string(password) = Dotenv["SMTP_PASSWORD"] else {
        logger.error("SMTP_PASSWORD not found in .env file")
        exit(1)
    }
    
    // Create an SMTP server instance
    let server = SMTPServer(host: host, port: port)
    
    // Use Task with await for async operations
    await Task {
        do {
            // Connect to the server
            print("Connecting to SMTP server...")

            try await server.connect()
            
            // Login with credentials
            print("Authenticating...")

			let authSuccess = try await server.authenticate(username: username, password: password)
            
            if authSuccess {
                logger.info("Authentication successful")
            } else {
                logger.error("Authentication failed")
                throw SMTPError.authenticationFailed("Authentication failed")
            }
            
            // Create a test email
            let sender = EmailAddress(name: "Test Sender", address: username)
            let recipient = EmailAddress(name: "Test Recipient", address: username) // Sending to self for testing
            
            // Download Swift logo at runtime
            print("Downloading Swift logo...")
            let logoURL = URL(string: "https://developer.apple.com/swift/images/swift-logo.svg")!
            let logoContentID = "swift-logo"
            let logoFilename = "swift-logo.svg"
            
            // Download the image data
            let (imageData, response) = try await URLSession.shared.data(from: logoURL)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "com.cocoanetics.SwiftSMTPCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to download Swift logo"])
            }
            
            print("Swift logo downloaded successfully (\(imageData.count) bytes)")
            
            // Create the email with both text and HTML content
            var email = Email(
                sender: sender,
                recipients: [recipient],
                subject: "HTML Email with Swift Logo from SwiftSMTPCLI",
                textBody: "This is a test email sent from the SwiftSMTPCLI application. This is the plain text version for email clients that don't support HTML."
            )
            
            // Add HTML body with the Swift logo
            let htmlBody = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="UTF-8">
                <title>Swift Email Test</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px; }
                    .header { display: flex; align-items: center; margin-bottom: 20px; }
                    .logo { margin-right: 15px; }
                    h1 { color: #F05138; margin: 0; }
                    .content { background-color: #f9f9f9; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
                    .footer { font-size: 12px; color: #666; border-top: 1px solid #eee; padding-top: 10px; }
                    code { background-color: #f0f0f0; padding: 2px 4px; border-radius: 4px; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace; }
                </style>
            </head>
            <body>
                <div class="header">
                    <div class="logo">
                        <img src="cid:\(logoContentID)" alt="Swift Logo" width="64" height="64">
                    </div>
                    <h1>Swift Email Test</h1>
                </div>
                <div class="content">
                    <p>Hello from <strong>SwiftSMTPCLI</strong>!</p>
                    <p>This is a test email demonstrating HTML formatting and embedded images using Swift's email capabilities.</p>
                    <p>Here's a simple Swift code example:</p>
                    <pre><code>let message = "Hello, Swift!"\nprint(message)</code></pre>
                </div>
                <div class="footer">
                    <p>This email was sent using SwiftSMTPCLI on \(formatCurrentDate())</p>
                </div>
            </body>
            </html>
            """
            
            // Get MIME type for the downloaded image
            let mimeType = "image/svg+xml" // SVG format from Apple's website
            
            // Create a custom attachment with inline disposition
            let attachment = Attachment(
                filename: logoFilename,
                mimeType: mimeType,
                data: imageData,
                contentID: logoContentID,
                isInline: true
            )
            
            // Add HTML body and inline image attachment
            email = email.withHTMLBody(htmlBody)
            
            // Create a custom email with the inline attachment
            // This ensures the attachment is only included once
            let customEmail = CustomEmail(
                sender: email.sender,
                recipients: email.recipients,
                subject: email.subject,
                textBody: email.textBody,
                htmlBody: email.htmlBody,
                inlineAttachments: [attachment],
                regularAttachments: []
            )
            
            print("Created HTML email with embedded Swift logo")
            
            // Send the custom email
            print("Sending HTML test email to \(recipient.address)...")
            try await server.sendCustomEmail(customEmail)
            print("Email sent successfully!")
            
            // Disconnect from the server
            print("Disconnecting...")
            try await server.disconnect()
        } catch {
            print("Error: \(error.localizedDescription)")
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }.value
    
} catch {
    print("Error: \(error.localizedDescription)")
    logger.error("Error: \(error.localizedDescription)")
    exit(1)
}

// Helper function to format the current date in a compatible way
func formatCurrentDate() -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .medium
    return dateFormatter.string(from: Date())
}

// Helper function to get MIME type from file URL using UTI
func getMimeTypeFromFileURL(_ fileURL: URL) -> String {
    // First try to get UTType from file extension
    if let fileExtension = fileURL.pathExtension.isEmpty ? nil : fileURL.pathExtension,
       let utType = UTType(filenameExtension: fileExtension) {
        // If we have a UTType, try to get its MIME type
        if let mimeType = utType.preferredMIMEType {
            return mimeType
        }
    }
    
    // Fallback to common extensions if UTI doesn't work
    let pathExtension = fileURL.pathExtension.lowercased()
    switch pathExtension {
    case "jpg", "jpeg":
        return "image/jpeg"
    case "png":
        return "image/png"
    case "gif":
        return "image/gif"
    case "svg":
        return "image/svg+xml"
    case "pdf":
        return "application/pdf"
    case "txt":
        return "text/plain"
    case "html", "htm":
        return "text/html"
    case "doc", "docx":
        return "application/msword"
    case "xls", "xlsx":
        return "application/vnd.ms-excel"
    case "zip":
        return "application/zip"
    default:
        return "application/octet-stream"
    }
}

// Custom email structure that properly handles inline attachments
struct CustomEmail {
    let sender: EmailAddress
    let recipients: [EmailAddress]
    let subject: String
    let textBody: String
    let htmlBody: String?
    let inlineAttachments: [Attachment]
    let regularAttachments: [Attachment]
}

// Extension to SMTPServer to add support for sending custom emails
extension SMTPServer {
    func sendCustomEmail(_ email: CustomEmail) async throws {
        // Send MAIL FROM command
        let mailFromCommand = MailFromCommand(senderAddress: email.sender.address)
        let mailFromSuccess = try await executeCommand(mailFromCommand)
        
        guard mailFromSuccess else {
            throw SMTPError.sendFailed("Server rejected sender")
        }
        
        // Send RCPT TO command for each recipient
        for recipient in email.recipients {
            let rcptToCommand = RcptToCommand(recipientAddress: recipient.address)
            let rcptToSuccess = try await executeCommand(rcptToCommand)
            
            guard rcptToSuccess else {
                throw SMTPError.sendFailed("Server rejected recipient \(recipient.address)")
            }
        }
        
        // Send DATA command
        let dataCommand = DataCommand()
        let dataSuccess = try await executeCommand(dataCommand)
        
        guard dataSuccess else {
            throw SMTPError.sendFailed("Server rejected DATA command")
        }
        
        // Construct custom email content
        let emailContent = constructCustomEmailContent(email)
        
        // Send email content
        let contentCommand = SendContentCommand(content: emailContent)
        let contentSuccess = try await executeCommand(contentCommand)
        
        guard contentSuccess else {
            throw SMTPError.sendFailed("Server rejected email content")
        }
        
        logger.info("Custom email sent successfully")
    }
    
    private func constructCustomEmailContent(_ email: CustomEmail) -> String {
        var content = ""
        
        // Add headers
        content += "From: \(email.sender.formatted)\r\n"
        content += "To: \(email.recipients.map { $0.formatted }.joined(separator: ", "))\r\n"
        content += "Subject: \(email.subject)\r\n"
        content += "MIME-Version: 1.0\r\n"
        
        // Generate boundaries
        let mainBoundary = "SwiftSMTP-Boundary-\(UUID().uuidString)"
        let altBoundary = "SwiftSMTP-Alt-Boundary-\(UUID().uuidString)"
        let relatedBoundary = "SwiftSMTP-Related-Boundary-\(UUID().uuidString)"
        
        let hasHtmlBody = email.htmlBody != nil
        let hasInlineAttachments = !email.inlineAttachments.isEmpty
        let hasRegularAttachments = !email.regularAttachments.isEmpty
        
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
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                    
                    // Add inline attachments
                    for attachment in email.inlineAttachments {
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
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.textBody)\r\n\r\n"
                    
                    // Add HTML part
                    content += "--\(altBoundary)\r\n"
                    content += "Content-Type: text/html; charset=UTF-8\r\n"
                    content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                    content += "\(email.htmlBody ?? "")\r\n\r\n"
                    
                    // End alternative boundary
                    content += "--\(altBoundary)--\r\n\r\n"
                }
            } else {
                // Just text, no HTML
                content += "--\(mainBoundary)\r\n"
                content += "Content-Type: text/plain; charset=UTF-8\r\n"
                content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
                content += "\(email.textBody)\r\n\r\n"
            }
            
            // Add regular attachments
            for attachment in email.regularAttachments {
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
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n\r\n"
            
            // Add inline attachments
            for attachment in email.inlineAttachments {
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
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.textBody)\r\n\r\n"
            
            // Add HTML part
            content += "--\(altBoundary)\r\n"
            content += "Content-Type: text/html; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += "\(email.htmlBody ?? "")\r\n\r\n"
            
            // End alternative boundary
            content += "--\(altBoundary)--\r\n"
        } else {
            // Simple text email
            content += "Content-Type: text/plain; charset=UTF-8\r\n"
            content += "Content-Transfer-Encoding: 8bit\r\n\r\n"
            content += email.textBody
        }
        
        return content
    }
} 
