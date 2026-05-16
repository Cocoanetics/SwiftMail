// String+RedactingTests.swift
// Tests for string extensions in the SwiftMailCore library

import SwiftMail
import Testing

@Suite("String Extensions Tests", .serialized, .timeLimit(.minutes(1)))
struct StringExtensionsTests {
    @Test("Credential redaction - LOGIN command")
    func loginCredentialRedaction() {
        let loginCommand = "A001 LOGIN username password123"
        let redactedLogin = loginCommand.redactAfter("LOGIN")
        #expect(redactedLogin == "A001 LOGIN [credentials redacted]", "LOGIN command should be properly redacted")
    }

    @Test("Credential redaction - AUTH command")
    func authCredentialRedaction() {
        let authCommand = "AUTH PLAIN dXNlcm5hbWUAcGFzc3dvcmQxMjM="
        let redactedAuth = authCommand.redactAfter("AUTH")
        #expect(redactedAuth == "AUTH [credentials redacted]", "AUTH command should be properly redacted")
    }

    @Test("Credential redaction - non-sensitive command")
    func testNonSensitiveCommand() {
        let nonSensitiveCommand = "A002 LIST \"\" *"
        let nonRedacted = nonSensitiveCommand.redactAfter("LOGIN")
        #expect(nonRedacted == nonSensitiveCommand, "Non-sensitive command should not be redacted")
    }

    @Test("Regex pattern - tagged LOGIN command")
    func taggedLoginCommand() {
        let taggedLogin = "A001 LOGIN user pass"
        let redacted = taggedLogin.redactAfter("LOGIN")
        #expect(redacted == "A001 LOGIN [credentials redacted]")
    }

    @Test("Regex pattern - tagged LOGIN command with extra spaces")
    func testTaggedLoginWithSpaces() {
        let taggedLoginWithSpaces = "  A001  LOGIN  user pass"
        let redacted = taggedLoginWithSpaces.redactAfter("LOGIN")
        #expect(redacted == "  A001  LOGIN [credentials redacted]")
    }

    @Test("Regex pattern - tagged AUTH command")
    func taggedAuthCommand() {
        let taggedAuth = "A002 AUTH PLAIN base64data"
        let redacted = taggedAuth.redactAfter("AUTH")
        #expect(redacted == "A002 AUTH [credentials redacted]")
    }

    @Test("Regex pattern - untagged AUTH command")
    func untaggedAuthCommand() {
        let untaggedAuth = "AUTH PLAIN base64data"
        let redacted = untaggedAuth.redactAfter("AUTH")
        #expect(redacted == "AUTH [credentials redacted]")
    }

    @Test("Regex pattern - LOGIN in text context")
    func testLoginInText() {
        let loginInText = "User attempted to LOGIN with incorrect credentials"
        let result = loginInText.redactAfter("LOGIN")
        #expect(result == loginInText, "Should not redact when LOGIN is not a command")
    }

    @Test("Regex pattern - LOGIN at end of string")
    func testLoginAtEnd() {
        let loginAtEnd = "Command was LOGIN"
        let result = loginAtEnd.redactAfter("LOGIN")
        #expect(result == loginAtEnd, "Should not redact when LOGIN is at the end with no credentials")
    }
}
