// Connect to the IMAP server
try await imapServer.connect()

// Authenticate with your credentials
try await imapServer.login(username: "user@example.com", password: "password") 