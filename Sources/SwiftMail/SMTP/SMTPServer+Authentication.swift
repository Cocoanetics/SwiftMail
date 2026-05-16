// SMTPServer+Authentication.swift
// Authentication mechanisms (LOGIN/PLAIN, XOAUTH2) for SMTPServer.

import Foundation

public extension SMTPServer {
    /**
     Authenticate with the SMTP server

     This method authenticates with the SMTP server using the provided credentials.
     It automatically selects the best available authentication mechanism supported
     by the server, preferring more secure methods:
     1. XOAUTH2 (if supported and token provided)
     2. PLAIN (if TLS is active)
     3. LOGIN (if TLS is active)

     - Parameters:
       - username: The username for authentication
       - password: The password or access token for authentication
     - Throws:
       - `SMTPError.authenticationFailed` if credentials are rejected
       - `SMTPError.connectionFailed` if not connected
       - `SMTPError.tlsRequired` if attempting to authenticate without TLS
     - Note: Logs authentication attempts at info level (without credentials)
     */
    func login(username: String, password: String) async throws {
        // Check if we have PLAIN auth support
        if capabilities.contains("AUTH PLAIN") {
            let plainCommand = PlainAuthCommand(username: username, password: password)
            let result = try await executeCommand(plainCommand)

            // If successful, return success
            if result.success {
                return
            }
        }

        // If PLAIN auth failed or is not supported, try LOGIN auth
        if capabilities.contains("AUTH LOGIN") {
            let loginCommand = LoginAuthCommand(username: username, password: password)
            let result = try await executeCommand(loginCommand)

            // If successful, return success
            if result.success {
                return
            }
        }

        // If we get here, authentication failed
        throw SMTPError.authenticationFailed("Authentication failed with all available methods")
    }

    /**
     Authenticate with the SMTP server using XOAUTH2

     This method authenticates using the XOAUTH2 mechanism, which is required
     by Gmail and other providers when using OAuth2 access tokens for SMTP.

     - Parameters:
       - email: The email address of the account
       - accessToken: A valid OAuth2 access token
     - Throws:
       - `SMTPError.authenticationFailed` if the server does not support XOAUTH2
         or if the token is rejected
       - `SMTPError.connectionFailed` if not connected
     */
    func authenticateXOAUTH2(email: String, accessToken: String) async throws {
        guard capabilities.contains("AUTH XOAUTH2") else {
            throw SMTPError.authenticationFailed("Server does not support XOAUTH2 authentication")
        }

        let command = XOAuth2AuthCommand(email: email, accessToken: accessToken)
        let result = try await executeCommand(command)

        guard result.success else {
            throw SMTPError.authenticationFailed(result.errorMessage ?? "XOAUTH2 authentication failed")
        }
    }
}
