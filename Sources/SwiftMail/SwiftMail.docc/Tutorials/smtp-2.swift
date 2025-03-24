// Connect to the SMTP server
try await smtpServer.connect()

// Authenticate with your credentials
try await smtpServer.authenticate(username: "user@example.com", password: "password") 