// AddressScanner+Recovery.swift
// Reading the common real-world malformations whose addresses are unambiguous.

import Foundation

extension AddressScanner {
    /// Reads an address-list element in `range` that doesn't match the grammar,
    /// by rules that return exactly the addresses written in it, or returns
    /// `nil`. No rule splits, merges or alters an address:
    ///
    /// - A group that runs to the end of the text without its ";" reads as if
    ///   it had one. Its members are the same whether the ";" was dropped or a
    ///   display name held a colon, as in `Support: Sales <s@example.com>`.
    /// - A mailbox whose display name breaks the phrase grammar reads by
    ///   ``recoverNameAddr(in:allowsCommas:)``.
    mutating func recoverElement(in range: Range<Int>) -> AddressListEntry? {
        position = range.lowerBound
        if range.upperBound == scalars.count, let group = try? readGroup(endsAtEndOfText: true), isAtEnd {
            return group
        }
        return recoverNameAddr(in: range, allowsCommas: false).map(AddressListEntry.mailbox)
    }

    /// A mailbox whose display name breaks the phrase grammar, such as
    /// `John [Sales] <john@example.com>`, a name holding a stray control byte,
    /// or `john@example.com <john@example.com>`. It is read as the angle-addr
    /// that ends `range`, with the text before it as the display name.
    ///
    /// The angle-addr must be well-formed and followed by nothing but CFWS. The
    /// text before it may hold anything except a line break that doesn't fold,
    /// an angle bracket, and, unless `allowsCommas`, a comma, outside
    /// quoted-strings and comments. An "@" there would mean a second address,
    /// as in the missing comma of `alice@example.com Bob <bob@example.com>`, so
    /// it is only accepted when that text is the same address.
    mutating func recoverNameAddr(in range: Range<Int>, allowsCommas: Bool) -> EmailAddress? {
        guard let open = lastTopLevelAngle(in: range) else { return nil }
        position = open
        guard let address = try? readAngleAddr(), (try? skipCFWS()) != nil, position == range.upperBound else {
            return nil
        }
        let prefix = range.lowerBound..<open
        guard isRecoverableName(prefix, allowsCommas: allowsCommas) else { return nil }
        if hasTopLevelAtSign(prefix), !isAddress(prefix, sameAs: address) {
            return nil
        }
        guard let name = recoveredName(prefix) else { return nil }
        return EmailAddress(name: name, address: address)
    }

    /// The index of the last "<" in `range` outside quoted-strings and comments.
    private func lastTopLevelAngle(in range: Range<Int>) -> Int? {
        var tracker = QuoteAndCommentTracker()
        var open: Int?
        for index in range where tracker.read(scalars[index]) && scalars[index] == "<" {
            open = index
        }
        return open
    }

    /// Whether `prefix` can be read as a recovered display name: balanced
    /// quoted-strings and comments, no line break that doesn't fold, and no
    /// angle bracket, or comma unless `allowsCommas`, outside them.
    private func isRecoverableName(_ prefix: Range<Int>, allowsCommas: Bool) -> Bool {
        var tracker = QuoteAndCommentTracker()
        for index in prefix {
            let scalar = scalars[index]
            if (scalar == "\r" || scalar == "\n") && !isFoldingLineBreak(at: index) {
                return false
            }
            if tracker.read(scalar), scalar == "<" || scalar == ">" || (scalar == "," && !allowsCommas) {
                return false
            }
        }
        return tracker.isBalanced
    }

    private func hasTopLevelAtSign(_ prefix: Range<Int>) -> Bool {
        var tracker = QuoteAndCommentTracker()
        return prefix.contains { tracker.read(scalars[$0]) && scalars[$0] == "@" }
    }

    /// Whether `prefix` is exactly one bare addr-spec naming `address`,
    /// ignoring case: a display name that repeats its own address.
    private func isAddress(_ prefix: Range<Int>, sameAs address: String) -> Bool {
        var probe = AddressScanner(String(unicodeScalars: scalars[prefix]))
        guard let mailbox = try? probe.readBareAddrSpec(), probe.isAtEnd, mailbox.name == nil else { return false }
        return mailbox.address.lowercased() == address.lowercased()
    }

    /// The display name a recovered mailbox's `prefix` stands for: the phrase
    /// rules of ``AddressPhrase``, with every run of characters that is not
    /// white space, a quoted-string or a comment read as a word.
    private mutating func recoveredName(_ prefix: Range<Int>) -> String? {
        position = prefix.lowerBound
        var tokens: [PhraseToken] = []
        while position < prefix.upperBound {
            guard let separator = try? skipCFWS(allowsControls: true) else { return nil }
            guard position < prefix.upperBound else { break }
            if current == "\"" {
                guard let content = try? readQuotedString(allowsControls: true) else { return nil }
                tokens.append(PhraseToken(kind: .quoted, text: content, separator: separator))
            } else {
                let start = position
                while position < prefix.upperBound, let scalar = current, !AddressSyntax.isWSP(scalar),
                      scalar != "\"", scalar != "(", scalar != "\r", scalar != "\n" {
                    position += 1
                }
                guard position > start else { return nil }
                let word = String(unicodeScalars: scalars[start..<position])
                tokens.append(PhraseToken(kind: .atom, text: word, separator: separator))
            }
        }
        return AddressPhrase.text(of: tokens)
    }
}

/// Follows quoted-strings and comments through address text, so that a
/// delimiter inside them isn't taken for syntax.
struct QuoteAndCommentTracker {
    private var isInQuote = false
    private var commentDepth = 0
    private var isEscaped = false

    /// Whether every quoted-string and comment read so far is closed.
    var isBalanced: Bool {
        !isInQuote && commentDepth == 0 && !isEscaped
    }

    /// Reads one scalar and returns whether it stands outside quoted-strings
    /// and comments, and is not escaped.
    mutating func read(_ scalar: Unicode.Scalar) -> Bool {
        if isEscaped {
            isEscaped = false
        } else if isInQuote {
            isEscaped = scalar == "\\"
            isInQuote = scalar != "\""
        } else if commentDepth > 0 {
            isEscaped = scalar == "\\"
            commentDepth += scalar == "(" ? 1 : (scalar == ")" ? -1 : 0)
        } else if scalar == "\"" {
            isInQuote = true
        } else if scalar == "(" {
            commentDepth = 1
        } else {
            return true
        }
        return false
    }
}
