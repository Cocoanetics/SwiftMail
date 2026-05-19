import Foundation
// Import the FoundationNetworking module on Linux platforms
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import SwiftMail

extension Email {
    /// Creates a demo email with Swift logo embedded inline.
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
        username: String
    ) async throws -> Email {
        let logoContentID = "swift-logo"
        let logoFilename = "swift-logo.svg"
        let logoData = try await downloadSwiftLogo()

        var email = Email(
            sender: sender,
            recipients: [recipient],
            ccRecipients: ccRecipient.map { [$0] } ?? [],
            bccRecipients: bccRecipient.map { [$0] } ?? [],
            subject: "HTML Email with Swift Logo from SwiftSMTPCLI",
            textBody: "This is a test email sent from the SwiftSMTPCLI application."
                + " This is the plain text version for email clients that don't support HTML."
        )
        email.htmlBody = htmlTemplate(
            logoContentID: logoContentID,
            recipient: recipient,
            ccRecipient: ccRecipient,
            bccRecipient: bccRecipient
        )
        email.attachments = [
            Attachment(
                filename: logoFilename,
                mimeType: String.mimeType(for: "svg"),
                data: logoData,
                contentID: logoContentID,
                isInline: true
            )
        ]

        print("Created HTML email with embedded Swift logo")
        return email
    }

    /// Download the Swift logo SVG over HTTPS, throwing if the response isn't a
    /// 200 OK.
    private static func downloadSwiftLogo() async throws -> Data {
        print("Downloading Swift logo...")
        let logoURL = URL(string: "https://developer.apple.com/swift/images/swift-logo.svg")!
        let session = URLSession(configuration: .default)
        let (imageData, response) = try await session.data(from: logoURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "com.cocoanetics.SwiftSMTPCLI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]
            )
        }
        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "com.cocoanetics.SwiftSMTPCLI",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to download Swift logo, status code: \(httpResponse.statusCode)"
                ]
            )
        }
        print("Swift logo downloaded successfully (\(imageData.count) bytes)")
        return imageData
    }

    // Long CSS/HTML lines below would otherwise trigger line_length warnings;
    // the disable is scoped to this helper.
    // swiftlint:disable line_length
    /// Build the HTML body for the demo email.
    private static func htmlTemplate(
        logoContentID: String,
        recipient: EmailAddress,
        ccRecipient: EmailAddress?,
        bccRecipient: EmailAddress?
    ) -> String {
        """
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

                <p>This email demonstrates CC and BCC functionality:</p>
                <ul>
                    <li>Primary recipient: \(recipient.description)</li>
                    \(ccRecipient.map { "<li>CC recipient: \($0.description)</li>" } ?? "")
                    \(bccRecipient.map { "<li>BCC recipient: \($0.description) (not visible in headers)</li>" } ?? "")
                </ul>
            </div>
            <div class="footer">
                <p>This email was sent using SwiftSMTPCLI on \(formatCurrentDate())</p>
            </div>
        </body>
        </html>
        """
    }
    // swiftlint:enable line_length
}

// Helper function to format the current date in a compatible way
private func formatCurrentDate() -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .medium
    return dateFormatter.string(from: Date())
}
