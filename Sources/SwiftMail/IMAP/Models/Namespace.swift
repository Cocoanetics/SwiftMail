import Foundation
import NIOIMAPCore

/// Description of a single IMAP namespace
public struct Namespace: Sendable {
    /// The prefix string of the namespace
    public let prefix: String
    /// The hierarchy delimiter if provided
    public let delimiter: Character?

    /// Initialize from raw values
    public init(prefix: String, delimiter: Character?) {
        self.prefix = prefix
        self.delimiter = delimiter
    }

    /// Initialize from ``NIOIMAPCore.NamespaceDescription``
    init(from nio: NIOIMAPCore.NamespaceDescription) {
        self.prefix = nio.string.stringValue
        self.delimiter = nio.delimiter
    }
}

/// The namespaces returned by the server
public struct NamespaceResponse: Sendable {
    /// Personal namespaces
    public let personal: [Namespace]
    /// Other user namespaces
    public let otherUsers: [Namespace]
    /// Shared namespaces
    public let shared: [Namespace]

    /// Initialize from raw values
    public init(personal: [Namespace], otherUsers: [Namespace], shared: [Namespace]) {
        self.personal = personal
        self.otherUsers = otherUsers
        self.shared = shared
    }

    /// Initialize from ``NIOIMAPCore.NamespaceResponse``
    init(from nio: NIOIMAPCore.NamespaceResponse) {
        self.personal = nio.userNamespace.map { Namespace(from: $0) }
        self.otherUsers = nio.otherUserNamespace.map { Namespace(from: $0) }
        self.shared = nio.sharedNamespace.map { Namespace(from: $0) }
    }

    /// All advertised namespaces in stable order (personal, other users, shared).
    public var all: [Namespace] {
        personal + otherUsers + shared
    }

    /// Resolve a user-facing mailbox path into the server namespace path.
    ///
    /// If the mailbox is already namespace-qualified (or `INBOX`) it is returned as-is.
    /// Otherwise the first personal namespace is used as prefix when available.
    public func resolveMailboxPath(_ mailbox: String) -> String {
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return mailbox
        }

        if trimmed.caseInsensitiveCompare("INBOX") == .orderedSame {
            return "INBOX"
        }

        if hasNamespacePrefix(trimmed) {
            return trimmed
        }

        guard let personalNamespace = personal.first, !personalNamespace.prefix.isEmpty else {
            return trimmed
        }

        let delimiter = personalNamespace.delimiter.map(String.init) ?? ""
        if delimiter.isEmpty || personalNamespace.prefix.hasSuffix(delimiter) {
            return personalNamespace.prefix + trimmed
        }
        return personalNamespace.prefix + delimiter + trimmed
    }

    /// Return mailbox name relative to namespace prefix for easier matching/display.
    public func relativeMailboxName(from mailbox: String) -> String {
        let trimmed = mailbox.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return mailbox
        }

        let sortedNamespaces = all.sorted { $0.prefix.count > $1.prefix.count }
        for namespace in sortedNamespaces where !namespace.prefix.isEmpty {
            if trimmed.hasPrefix(namespace.prefix) {
                return String(trimmed.dropFirst(namespace.prefix.count))
            }
        }

        return trimmed
    }

    /// Build namespace-aware LIST patterns for the provided wildcard.
    ///
    /// This expands patterns across all known namespace prefixes so listings include
    /// personal/other/shared roots when servers scope LIST results by namespace.
    public func listingPatterns(for wildcard: String) -> [String] {
        guard !all.isEmpty else {
            return [wildcard]
        }

        var patterns: [String] = []
        func appendUnique(_ value: String) {
            if !value.isEmpty && !patterns.contains(value) {
                patterns.append(value)
            }
        }

        for namespace in all {
            if namespace.prefix.isEmpty {
                appendUnique(wildcard)
                continue
            }

            appendUnique(namespace.prefix + wildcard)

            if wildcard == "*" || wildcard == "%" {
                let root: String
                if let delimiter = namespace.delimiter.map(String.init), namespace.prefix.hasSuffix(delimiter) {
                    root = String(namespace.prefix.dropLast(delimiter.count))
                } else {
                    root = namespace.prefix
                }
                appendUnique(root)
            }
        }

        if patterns.isEmpty {
            appendUnique(wildcard)
        }

        return patterns
    }

    private func hasNamespacePrefix(_ mailbox: String) -> Bool {
        for namespace in all where !namespace.prefix.isEmpty {
            if mailbox.hasPrefix(namespace.prefix) {
                return true
            }
        }
        return false
    }
}
