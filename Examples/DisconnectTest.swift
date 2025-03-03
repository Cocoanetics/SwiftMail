// DisconnectTest.swift
// A simple test program to verify the DisconnectCommand implementation

import Foundation
import SwiftIMAP
import os.log

// Create a logger
let logger = Logger(subsystem: "com.example.DisconnectTest", category: "Main")

// Main async function
@main
struct DisconnectTest {
    static func main() async {
        do {
            // Create an IMAP server connection
            let server = IMAPServer(host: "imap.gmail.com", port: 993)
            
            // Connect to the server
            logger.notice("Connecting to server...")
            try await server.connect()
            logger.notice("Connected successfully")
            
            // Logout from the server
            logger.notice("Logging out...")
            try await server.logout()
            logger.notice("Logged out successfully")
            
            // Disconnect from the server
            logger.notice("Disconnecting...")
            try await server.disconnect()
            logger.notice("Disconnected successfully")
            
            logger.notice("Test completed successfully")
        } catch {
            logger.error("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
} 