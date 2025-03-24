// Select the INBOX mailbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")

// Print mailbox information
print("Mailbox contains \(mailboxInfo.messageCount) messages") 