do {
    // Send the email
    try await smtpServer.sendEmail(email)
    print("Email sent successfully!")
} catch {
    print("Failed to send email: \(error)")
} 