// Logout from the server
try await imapServer.logout()

// Close the connection
try await imapServer.close() 