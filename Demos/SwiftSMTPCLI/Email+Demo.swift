import Foundation

// Import the FoundationNetworking module on Linux platforms
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import SwiftMail

extension Email {
    /// Creates a demo email with Swift logo embedded inline
    /// - Parameters:
    ///   - sender: The email sender
    ///   - recipient: The primary recipient
    ///   - ccRecipient: An optional CC recipient
    ///   - bccRecipient: An optional BCC recipient
    ///   - username: The username used in the email (typically same as sender address)
    /// - Returns: A configured email with HTML body and inline Swift logo
    static func demo(
        sender: EmailAddress,
        recipient: EmailAddress,
        ccRecipient: EmailAddress? = nil,
        bccRecipient: EmailAddress? = nil,
        username _: String
    ) async throws -> Email {
        print("Downloading Swift logo...")
        let logoURL = URL(string: "https://developer.apple.com/swift/images/swift-logo.svg")!
        let logoContentID = "swift-logo"
        let logoFilename = "swift-logo.svg"
        let imageData = try await downloadSwiftLogo(from: logoURL)
        print("Swift logo downloaded successfully (\(imageData.count) bytes)")

        var email = Email(
            sender: sender,
            recipients: [recipient],
            ccRecipients: ccRecipient != nil ? [ccRecipient!] : [],
            bccRecipients: bccRecipient != nil ? [bccRecipient!] : [],
            subject: "HTML Email with Swift Logo from SwiftSMTPCLI",
            textBody: "This is a test email sent from the SwiftSMTPCLI application. "
                + "This is the plain text version for email clients that don't support HTML."
        )

        email.htmlBody = buildDemoHTMLBody(
            recipient: recipient,
            ccRecipient: ccRecipient,
            bccRecipient: bccRecipient,
            logoContentID: logoContentID
        )
        email.attachments = [Attachment(
            filename: logoFilename,
            mimeType: String.mimeType(for: logoURL.pathExtension),
            data: imageData,
            contentID: logoContentID,
            isInline: true
        )]

        print("Created HTML email with embedded Swift logo")
        return email
    }

    /// Download the Swift logo image data, validating the HTTP response.
    private static func downloadSwiftLogo(from logoURL: URL) async throws -> Data {
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let (imageData, response) = try await session.data(from: logoURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "com.cocoanetics.SwiftSMTPCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]
            )
        }

        guard httpResponse.statusCode == 200 else {
            let description = "Failed to download Swift logo, status code: \(httpResponse.statusCode)"
            throw NSError(
                domain: "com.cocoanetics.SwiftSMTPCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }

        return imageData
    }

    /// Build the HTML body for the demo email, including the inline Swift logo and CC/BCC details.
    private static func buildDemoHTMLBody(
        recipient: EmailAddress,
        ccRecipient: EmailAddress?,
        bccRecipient: EmailAddress?,
        logoContentID: String
    ) -> String {
        let cssBlock = renderDemoCSSBlock()
        let recipientsBlock = renderDemoRecipientsBlock(
            recipient: recipient,
            ccRecipient: ccRecipient,
            bccRecipient: bccRecipient
        )
        let demoParagraph = "This is a test email demonstrating HTML formatting and embedded images "
            + "using Swift's email capabilities."
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Swift Email Test</title>
            \(cssBlock)
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
                <p>\(demoParagraph)</p>
                <p>Here's a simple Swift code example:</p>
                <pre><code>let message = "Hello, Swift!"\nprint(message)</code></pre>

                <p>This email demonstrates CC and BCC functionality:</p>
                \(recipientsBlock)
            </div>
            <div class="footer">
                <p>This email was sent using SwiftSMTPCLI on \(formatCurrentDate())</p>
            </div>
        </body>
        </html>
        """
    }

    /// Render the `<style>` block used by the demo HTML email.
    private static func renderDemoCSSBlock() -> String {
        // swiftlint:disable:next line_length
        let bodyCSS = "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;"
        // swiftlint:disable:next line_length
        let codeCSS = "background-color: #f0f0f0; padding: 2px 4px; border-radius: 4px; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace;"
        return """
        <style>
            body { \(bodyCSS) }
            .header { display: flex; align-items: center; margin-bottom: 20px; }
            .logo { margin-right: 15px; }
            h1 { color: #F05138; margin: 0; }
            .content { background-color: #f9f9f9; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
            .footer { font-size: 12px; color: #666; border-top: 1px solid #eee; padding-top: 10px; }
            code { \(codeCSS) }
        </style>
        """
    }

    /// Render the `<ul>` listing the primary recipient plus optional CC/BCC entries.
    private static func renderDemoRecipientsBlock(
        recipient: EmailAddress,
        ccRecipient: EmailAddress?,
        bccRecipient: EmailAddress?
    ) -> String {
        let ccLine = ccRecipient != nil ? "<li>CC recipient: \(ccRecipient!.description)</li>" : ""
        let bccLine = bccRecipient != nil
            ? "<li>BCC recipient: \(bccRecipient!.description) (not visible in headers)</li>"
            : ""
        return """
        <ul>
            <li>Primary recipient: \(recipient.description)</li>
            \(ccLine)
            \(bccLine)
        </ul>
        """
    }
}

/// Helper function to format the current date in a compatible way
private func formatCurrentDate() -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .medium
    return dateFormatter.string(from: Date())
}
