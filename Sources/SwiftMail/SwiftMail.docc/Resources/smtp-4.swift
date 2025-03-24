import SwiftMail

// Create an SMTP server instance
let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)

// Connect to the SMTP server
try await smtpServer.connect()

// Authenticate with your credentials
try await smtpServer.login(username: "user@example.com", password: "password")

// Create sender and recipients
let sender = EmailAddress(name: "Test Sender", address: "sender@example.org")
let recipient = EmailAddress(name: "Test Recipient", address: "recipient@example.org") // Primary recipient

// Create a new email message
let email = Email(sender: sender,
                  recipients: [recipient],
                  subject: "Hello from SwiftMail",
                  textBody: "This is a test email sent using SwiftMail."
            )
