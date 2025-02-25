// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftDotenv

print("SwiftIMAP - IMAP Client using .env credentials")
print("----------------------------------------------")

// Path to the .env file (hardcoded as requested)
let envFilePath = "/Users/oliver/Developer/.env"

do {
    // Configure SwiftDotenv with the specified path
    try Dotenv.configure(atPath: envFilePath)
    
    // Access IMAP credentials using dynamic member lookup with case let pattern matching
    guard case let .string(host) = Dotenv["IMAP_HOST"] else {
        print("Error: IMAP_HOST not found in .env file")
        exit(1)
    }
    
    guard case let .integer(port) = Dotenv["IMAP_PORT"] else {
        print("Error: IMAP_PORT not found or invalid in .env file")
        exit(1)
    }
    
    guard case let .string(username) = Dotenv["IMAP_USERNAME"] else {
        print("Error: IMAP_USERNAME not found in .env file")
        exit(1)
    }
    
    guard case .string(_) = Dotenv["IMAP_PASSWORD"] else {
        print("Error: IMAP_PASSWORD not found in .env file")
        exit(1)
    }
    
    // Display the loaded credentials (in a real app, you wouldn't print the password)
    print("IMAP Credentials loaded successfully:")
    print("Host: \(host)")
    print("Port: \(port)")
    print("Username: \(username)")
    print("Password: ********")
    
    // Here you would typically use these credentials to connect to the IMAP server
    // For example:
    // let imapClient = IMAPClient(host: host, port: port, username: username, password: password)
    // try imapClient.connect()
    
} catch {
    print("Error loading .env file: \(error)")
    exit(1)
}
