// Get the latest 10 messages
if let latestMessagesSet = mailboxInfo.latest(10) {
    // Fetch the messages
    let emails = try await imapServer.fetchMessages(using: latestMessagesSet)
    print("\nFetched \(emails.count) messages")
} 