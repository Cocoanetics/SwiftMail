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

// Select the INBOX mailbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")

// Print mailbox information
print("Mailbox contains \(mailboxInfo.messageCount) messages")

// Get the latest 10 messages
if let latestMessagesSet = mailboxInfo.latest(10) {
        // Stream the messages one by one
        for try await email in imapServer.fetchMessages(using: latestMessagesSet) {
                print("\nFetched message #\(email.sequenceNumber)")
        }
}

// Will store results using sequence numbers
let unreadMessagesSet: MessageIdentifierSet<SequenceNumber>

// Will store results using UIDs
let sampleMessagesSet: MessageIdentifierSet<UID>
