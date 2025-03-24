import SwiftMail

// Create an IMAP server instance
let imapServer = IMAPServer(host: "imap.example.com", port: 993)

// Connect to the IMAP server
try await imapServer.connect()

// Authenticate with your credentials
try await imapServer.login(username: "user@example.com", password: "password")

// List all available mailboxes
let mailboxes = try await imapServer.listMailboxes()

// Print mailbox names
for mailbox in mailboxes {
	print("📬 \(mailbox.name)")
}
