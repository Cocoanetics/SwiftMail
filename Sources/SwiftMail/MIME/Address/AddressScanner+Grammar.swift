// AddressScanner+Grammar.swift
// The RFC 5322 §3.4 address grammar, with the obsolete forms of §4.4.

import Foundation

// MARK: - Addresses, groups and mailboxes

extension AddressScanner {
    /// address = mailbox / group
    mutating func readAddress() throws -> AddressListEntry {
        let start = position
        let isGroup = (try? readPhrase()) != nil && current == ":"
        position = start
        if isGroup {
            return try readGroup()
        }
        return .mailbox(try readMailbox())
    }

    /// group = display-name ":" [group-list] ";" [CFWS], where the group-list
    /// may hold the empty elements of obs-group-list and obs-mbox-list. Groups
    /// don't nest, so every member is a mailbox.
    mutating func readGroup() throws -> AddressListEntry {
        let name = try readPhrase()
        try expect(":")
        var members: [EmailAddress] = []
        while true {
            try skipCFWS()
            if consume(";") {
                break
            }
            if consume(",") {
                continue
            }
            members.append(try readMailbox())
            guard current == "," || current == ";" else { throw AddressSyntaxError() }
        }
        try skipCFWS()
        return .group(name: name, members: members)
    }

    /// mailbox = name-addr / addr-spec, with the CFWS around it.
    mutating func readMailbox() throws -> EmailAddress {
        let start = position
        if let mailbox = try? readNameAddr() {
            return mailbox
        }
        position = start
        return try readBareAddrSpec()
    }

    /// name-addr = [display-name] angle-addr
    mutating func readNameAddr() throws -> EmailAddress {
        try skipCFWS()
        var name: String?
        if current != "<" {
            name = try readPhrase()
        }
        let address = try readAngleAddr()
        try skipCFWS()
        return EmailAddress(name: name, address: address)
    }

    /// An addr-spec without angle brackets. Its first non-empty trailing comment
    /// becomes the display name: RFC 5322 §3.4 notes that legacy mail writes a
    /// mailbox as `user@example.com (Name)`, and IMAP servers and other parsers
    /// read that comment as the name.
    mutating func readBareAddrSpec() throws -> EmailAddress {
        let localPart = try readLocalPart()
        try expect("@")
        let domain = try readDomain()
        let name = domain.trailing.comments.lazy.map(AddressPhrase.commentText).first { !$0.isEmpty }
        return EmailAddress(name: name, address: AddressSyntax.addrSpec(localPart: localPart, domain: domain.text))
    }
}

// MARK: - Angle addresses and addr-specs

extension AddressScanner {
    /// angle-addr = [CFWS] "<" addr-spec ">" [CFWS], or obs-angle-addr, which
    /// puts a source route before the addr-spec. RFC 5322 §4.4 says to ignore
    /// the route. Returns the canonical addr-spec.
    mutating func readAngleAddr() throws -> String {
        try skipCFWS()
        try expect("<")
        try skipCFWS()
        if current == "@" || current == "," {
            try skipObsRoute()
        }
        let localPart = try readLocalPart()
        try expect("@")
        let domain = try readDomain()
        try expect(">")
        return AddressSyntax.addrSpec(localPart: localPart, domain: domain.text)
    }

    /// obs-route = obs-domain-list ":", where obs-domain-list is
    /// `*(CFWS / ",") "@" domain *("," [CFWS] ["@" domain])`. The route ends at
    /// its own ":"; a colon inside the addr-spec's quoted-string or domain
    /// literal is read by those tokens and never reaches here.
    mutating func skipObsRoute() throws {
        var hasDomain = false
        var isAfterDomain = false
        while true {
            try skipCFWS()
            if consume(",") {
                isAfterDomain = false
            } else if !isAfterDomain, consume("@") {
                _ = try readDomain()
                hasDomain = true
                isAfterDomain = true
            } else if hasDomain, consume(":") {
                return
            } else {
                throw AddressSyntaxError()
            }
        }
    }

    /// local-part = dot-atom / quoted-string / obs-local-part, returned as the
    /// text it stands for: its words joined by dots, without CFWS or quoting.
    /// CFWS may surround the dots (obs-local-part), but two words need a dot
    /// between them: `first last` is not a local-part.
    mutating func readLocalPart() throws -> String {
        var words: [String] = []
        repeat {
            try skipCFWS()
            words.append(try readWord())
            try skipCFWS()
        } while consume(".")
        return words.joined(separator: ".")
    }

    /// word = atom / quoted-string, as its text.
    mutating func readWord() throws -> String {
        if current == "\"" {
            return try readQuotedString()
        }
        guard let atom = readAtom() else { throw AddressSyntaxError() }
        return atom
    }

    /// domain = dot-atom / domain-literal / obs-domain, without CFWS, together
    /// with the CFWS that follows it.
    mutating func readDomain() throws -> (text: String, trailing: CFWSRun) {
        try skipCFWS()
        if current == "[" {
            let literal = try readDomainLiteral()
            let trailing = try skipCFWS()
            return (literal, trailing)
        }
        var labels: [String] = []
        while true {
            try skipCFWS()
            guard let label = readAtom() else { throw AddressSyntaxError() }
            labels.append(label)
            let trailing = try skipCFWS()
            if !consume(".") {
                return (labels.joined(separator: "."), trailing)
            }
        }
    }
}

// MARK: - Phrases

extension AddressScanner {
    /// phrase = 1*word / obs-phrase, where obs-phrase lets "." follow the first
    /// word. Returns the display-name text the phrase stands for, as
    /// ``AddressPhrase`` builds it.
    mutating func readPhrase() throws -> String {
        var tokens: [PhraseToken] = []
        while true {
            let separator = try skipCFWS()
            guard let token = try readPhraseToken(isAfterWord: !tokens.isEmpty, separator: separator) else {
                break
            }
            tokens.append(token)
        }
        guard !tokens.isEmpty else { throw AddressSyntaxError() }
        return AddressPhrase.text(of: tokens)
    }

    private mutating func readPhraseToken(
        isAfterWord: Bool,
        separator: CFWSRun
    ) throws -> PhraseToken? {
        if current == "\"" {
            let content = try readQuotedString()
            return PhraseToken(kind: .quoted, text: content, separator: separator)
        }
        if isAfterWord, consume(".") {
            return PhraseToken(kind: .dot, text: ".", separator: separator)
        }
        guard let atom = readAtom() else { return nil }
        return PhraseToken(kind: .atom, text: atom, separator: separator)
    }
}
