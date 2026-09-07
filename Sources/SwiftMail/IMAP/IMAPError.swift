// IMAPError.swift
// Custom IMAP errors

import Foundation
import NIOIMAPCore

/// Errors that can occur during IMAP operations
public enum IMAPError: Error {
    case greetingFailed(String)
    case loginFailed(String)
    case selectFailed(String)
    case logoutFailed(String)
    case fetchFailed(String)
    case connectionFailed(String)
    case timeout
    case invalidArgument(String)
    case emptyIdentifierSet
    case commandFailed(String)
    /// SEARCH, UID SEARCH, or SORT was answered `NO [BADCHARSET ...]` (RFC 3501 §7.1, RFC 9051 §7.1):
    /// the server does not support the CHARSET the command carried. `supportedCharsets` is the
    /// server's optional list of charsets it does accept; empty when it named none.
    case searchCharsetNotSupported(supportedCharsets: [String], reason: String)
    case createFailed(String)
    case deleteFailed(String)
    case renameFailed(String)
    case copyFailed(String)
    case storeFailed(String)
    case expungeFailed(String)
    case moveFailed(String)
    /// MOVE may have changed server state before failing, but no trustworthy mapping is available.
    /// Callers must refresh both mailboxes and must not retry the original identifiers.
    case moveFailedAfterPossiblePartialCompletion(String)
    /// MOVE completed for the verified subset in `copyUID` before ending with tagged NO/BAD.
    /// Callers should reconcile both mailboxes from this mapping and must not retry blindly.
    case moveFailedAfterPartialCompletion(copyUID: CopyUID, reason: String)
    /// Fallback COPY completed and created the verified destinations in `copyUID`, but a later
    /// STORE or EXPUNGE failed. Source flags/removal are unknown and must be refreshed.
    case moveFallbackFailedAfterCopy(copyUID: CopyUID, reason: String)
    /// The command completed with tagged OK, but its present COPYUID evidence was malformed,
    /// conflicting, or unverifiable. The provider operation completed; callers must not resend it.
    case malformedCopyUIDAfterTaggedOK(String)
    case commandNotSupported(String)
    case authFailed(String)
    case unsupportedAuthMechanism(String)
    /// The APPEND payload exceeds the server-advertised APPENDLIMIT.
    ///
    /// Associated values: `(payloadSize, limit)` — both in bytes.
    case appendLimitExceeded(Int, Int)
}

// Add CustomStringConvertible conformance for better error messages
extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
            case .connectionFailed(let reason):
                return "Connection failed: \(reason)"
            case .loginFailed(let reason):
                return "Login failed: \(reason)"
            case .selectFailed(let reason):
                return "Select mailbox failed: \(reason)"
            case .fetchFailed(let reason):
                return "Fetch failed: \(reason)"
            case .logoutFailed(let reason):
                return "Logout failed: \(reason)"
            case .timeout:
                return "Operation timed out"
            case .greetingFailed(let reason):
                return "Greeting failed: \(reason)"
            case .invalidArgument(let reason):
                return "Invalid argument: \(reason)"
            case .emptyIdentifierSet:
                return "Empty identifier set provided"
            case .commandFailed(let reason):
                return "Command failed: \(reason)"
            case .searchCharsetNotSupported(_, let reason):
                return "Search charset not supported: \(reason)"
            case .createFailed(let reason):
                return "Create mailbox failed: \(reason)"
            case .deleteFailed(let reason):
                return "Delete mailbox failed: \(reason)"
            case .renameFailed(let reason):
                return "Rename mailbox failed: \(reason)"
            case .copyFailed(let reason):
                return "Copy failed: \(reason)"
            case .storeFailed(let reason):
                return "Store failed: \(reason)"
            case .expungeFailed(let reason):
                return "Expunge failed: \(reason)"
            case .moveFailed(let reason):
                return "Move failed: \(reason)"
            case .moveFailedAfterPossiblePartialCompletion(let reason):
                return "Move may have partially completed before failing: \(reason)"
            case .moveFailedAfterPartialCompletion(_, let reason):
                return "Move partially completed before failing: \(reason)"
            case .moveFallbackFailedAfterCopy(_, let reason):
                return "Move fallback copied messages before failing: \(reason)"
            case .malformedCopyUIDAfterTaggedOK(let reason):
                return "Command completed but returned untrusted COPYUID data: \(reason)"
            case .commandNotSupported(let reason):
                return "Command not supported: \(reason)"
            case .authFailed(let reason):
                return "Authentication failed: \(reason)"
            case .unsupportedAuthMechanism(let reason):
                return "Unsupported authentication mechanism: \(reason)"
            case .appendLimitExceeded(let payloadSize, let limit):
                return "Append payload (\(payloadSize) bytes) exceeds server APPENDLIMIT (\(limit) bytes)"
        }
    }
}

// Add LocalizedError conformance for better error messages in system contexts
extension IMAPError: LocalizedError {
    public var errorDescription: String? {
        return description
    }

    public var failureReason: String? {
        switch self {
            case .connectionFailed(let reason):
                return "Could not establish connection to the IMAP server: \(reason)"
            case .loginFailed(let reason):
                return "Authentication with the IMAP server failed: \(reason)"
            case .selectFailed(let reason):
                return "Could not select the requested mailbox: \(reason)"
            case .fetchFailed(let reason):
                return "Failed to fetch messages: \(reason)"
            case .logoutFailed(let reason):
                return "Failed to properly logout: \(reason)"
            case .timeout:
                return "The operation took too long and timed out"
            case .greetingFailed(let reason):
                return "Server did not provide a proper greeting: \(reason)"
            case .invalidArgument(let reason):
                return "An invalid argument was provided: \(reason)"
            case .emptyIdentifierSet:
                return "An empty set of message identifiers was provided"
            case .commandFailed(let reason):
                return "The IMAP command failed to execute: \(reason)"
            case .searchCharsetNotSupported(let supportedCharsets, _):
                if supportedCharsets.isEmpty {
                    return "The server does not support the charset the search used"
                }
                return "The server does not support the charset the search used; "
                    + "it supports \(supportedCharsets.joined(separator: ", "))"
            case .createFailed(let reason):
                return "Failed to create mailbox: \(reason)"
            case .deleteFailed(let reason):
                return "Failed to delete mailbox: \(reason)"
            case .renameFailed(let reason):
                return "Failed to rename mailbox: \(reason)"
            case .copyFailed(let reason):
                return "Failed to copy messages: \(reason)"
            case .storeFailed(let reason):
                return "Failed to store flags: \(reason)"
            case .expungeFailed(let reason):
                return "Failed to expunge deleted messages: \(reason)"
            case .moveFailed(let reason):
                return "Failed to move messages: \(reason)"
            case .moveFailedAfterPossiblePartialCompletion(let reason):
                return "The server may have moved or copied messages before failing: \(reason)"
            case .moveFailedAfterPartialCompletion(_, let reason):
                return "The server moved a verified subset of messages before failing: \(reason)"
            case .moveFallbackFailedAfterCopy(_, let reason):
                return "The fallback created verified destination copies, but source state is unknown: \(reason)"
            case .malformedCopyUIDAfterTaggedOK(let reason):
                return "The command completed, but its COPYUID mapping could not be trusted: \(reason)"
            case .commandNotSupported(let reason):
                return "The requested command is not supported by the server: \(reason)"
            case .authFailed(let reason):
                return "The IMAP authentication failed: \(reason)"
            case .unsupportedAuthMechanism(let reason):
                return "The server does not support the requested authentication mechanism: \(reason)"
            case .appendLimitExceeded(let payloadSize, let limit):
                return "The message (\(payloadSize) bytes) is too large for the server limit of \(limit) bytes"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
            case .connectionFailed:
                return "Check your network connection and server settings."
            case .loginFailed:
                return "Verify your username and password."
            case .selectFailed:
                return "Make sure the mailbox exists and you have permission to access it."
            case .fetchFailed:
                return "Ensure you have selected a mailbox and have valid message identifiers."
            case .timeout:
                return "Try again later when the server might be less busy."
            case .commandFailed(let reason) where reason.contains("not allowed now"):
                return "Make sure to select a mailbox before performing this operation."
            case .commandNotSupported:
                return "This operation may not be supported by your email provider."
            case .authFailed:
                return "Verify your OAuth credentials or request a fresh access token."
            case .unsupportedAuthMechanism:
                return "Check that your email provider supports XOAUTH2 for IMAP connections."
            case .moveFailedAfterPartialCompletion:
                return "Do not retry blindly. Reconcile both mailboxes using the verified COPYUID mapping."
            case .moveFallbackFailedAfterCopy:
                return "Do not retry. Reconcile the destination copies using COPYUID and refresh the source mailbox."
            case .moveFailed, .moveFailedAfterPossiblePartialCompletion:
                return "Do not retry. Refresh both mailboxes and reconcile their current state first."
            case .malformedCopyUIDAfterTaggedOK:
                return "Do not retry. The command completed; refresh the affected mailboxes before continuing."
            case .searchCharsetNotSupported:
                return "Retry with a charset the server supports: US-ASCII-only search text for SEARCH, "
                    + "or a supported sortCharset for SORT."
            default:
                return "Check the error details and try again."
        }
    }
}

extension IMAPError {
    /// The error for a rejected SEARCH, UID SEARCH, or SORT: the typed BADCHARSET case when the
    /// response carries that code, otherwise `commandFailed` with the response code kept in wire
    /// form, so `[NONEXISTENT]`, `[THROTTLED]` and the like stay readable in the message.
    static func searchRejected(operation: String, status: String, responseText: ResponseText) -> IMAPError {
        // Rendered by hand rather than through ResponseText's description: NIO accepts a NO or
        // BAD with no text (iCloud, Oracle) and the description substitutes a placeholder space,
        // which would turn the established "NO " wording of a code-less rejection into "NO  ".
        var reason = "\(operation) failed: \(status)"
        if let code = responseText.code {
            reason += " [\(code.debugDescription)]"
        }
        reason += " \(responseText.text)"
        if case .badCharset(let supportedCharsets)? = responseText.code {
            return .searchCharsetNotSupported(supportedCharsets: supportedCharsets, reason: reason)
        }
        return .commandFailed(reason)
    }

    static func moveFallbackFailed(after copyUID: CopyUID?, underlying error: Error) -> IMAPError {
        let reason = "COPY completed before fallback failed: \(error)"
        if let copyUID {
            return .moveFallbackFailedAfterCopy(copyUID: copyUID, reason: reason)
        }
        return .moveFailedAfterPossiblePartialCompletion(reason)
    }
}
