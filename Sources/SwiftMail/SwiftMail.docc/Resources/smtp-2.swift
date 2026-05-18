import SwiftMail

// Create an SMTP server instance
let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)

// Connect to the SMTP server
try await smtpServer.connect()

// Authenticate with your credentials
try await smtpServer.login(username: "user@example.com", password: "password")
