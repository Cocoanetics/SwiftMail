import Foundation
import ArgumentParser
import SwiftDotenv
import SwiftMail

enum IMAPAuthMethod {
    case login
    case xoauth2

    static func fromEnvironment(_ rawValue: String?) throws -> (method: IMAPAuthMethod, label: String) {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            ?? "LOGIN"

        switch normalized {
        case "", "LOGIN":
            return (.login, "LOGIN")
        case "XOAUTH2", "OAUTH2", "MODERN":
            return (.xoauth2, normalized)
        default:
            throw ValidationError(
                "Invalid IMAP_AUTH_METHOD=\(normalized). "
                + "Supported values: LOGIN, XOAUTH2, OAUTH2, MODERN."
            )
        }
    }
}

struct IMAPEnvironment {
    let host: String
    let port: Int
    let username: String
    let authMethod: IMAPAuthMethod
    let authMethodLabel: String
    let password: String?
    let accessToken: String?
}

func loadIMAPEnvironment() throws -> IMAPEnvironment {
    try Dotenv.configure()

    guard case let .string(host) = Dotenv["IMAP_HOST"] else {
        throw ValidationError("Missing IMAP_HOST in .env")
    }

    guard case let .integer(port) = Dotenv["IMAP_PORT"] else {
        throw ValidationError("Missing or invalid IMAP_PORT in .env")
    }

    guard case let .string(username) = Dotenv["IMAP_USERNAME"] else {
        throw ValidationError("Missing IMAP_USERNAME in .env")
    }

    let rawAuthMethod: String?
    if case let .string(value) = Dotenv["IMAP_AUTH_METHOD"] {
        rawAuthMethod = value
    } else {
        rawAuthMethod = nil
    }

    let (authMethod, authMethodLabel) = try IMAPAuthMethod.fromEnvironment(rawAuthMethod)

    switch authMethod {
    case .login:
        guard case let .string(password) = Dotenv["IMAP_PASSWORD"] else {
            throw ValidationError("IMAP_AUTH_METHOD=LOGIN requires IMAP_PASSWORD in .env")
        }

        return IMAPEnvironment(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            authMethodLabel: authMethodLabel,
            password: password,
            accessToken: nil
        )

    case .xoauth2:
        guard case let .string(accessToken) = Dotenv["IMAP_ACCESS_TOKEN"] else {
            throw ValidationError("IMAP_AUTH_METHOD=\(authMethodLabel) requires IMAP_ACCESS_TOKEN in .env")
        }

        return IMAPEnvironment(
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            authMethodLabel: authMethodLabel,
            password: nil,
            accessToken: accessToken
        )
    }
}

func authenticate(server: IMAPServer, using environment: IMAPEnvironment) async throws {
    switch environment.authMethod {
    case .login:
        guard let password = environment.password else {
            throw ValidationError("IMAP_AUTH_METHOD=LOGIN requires IMAP_PASSWORD in .env")
        }
        print("Authenticating using LOGIN as \(environment.username)...")
        try await server.login(username: environment.username, password: password)
        print("Authentication OK (LOGIN).")

    case .xoauth2:
        guard let accessToken = environment.accessToken else {
            throw ValidationError("IMAP_AUTH_METHOD=\(environment.authMethodLabel) requires IMAP_ACCESS_TOKEN in .env")
        }
        print(
            "Authenticating using XOAUTH2 as \(environment.username) "
            + "(IMAP_AUTH_METHOD=\(environment.authMethodLabel))..."
        )
        try await server.authenticateXOAUTH2(email: environment.username, accessToken: accessToken)
        print("Authentication OK (XOAUTH2).")
    }
}
