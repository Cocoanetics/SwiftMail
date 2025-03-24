// List all available mailboxes
let mailboxes = try await imapServer.listMailboxes()

// Print mailbox names
for mailbox in mailboxes {
    print("�� \(mailbox.name)")
} 