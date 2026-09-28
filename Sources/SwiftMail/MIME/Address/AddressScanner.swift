// AddressScanner.swift
// The lexical layer of the address parser: RFC 5322 §3.2 tokens, read by Unicode scalar.

import Foundation

/// A mismatch between address text and the RFC 5322 grammar. It only steers
/// ``AddressParser`` between alternatives and into recovery, and never leaves it.
struct AddressSyntaxError: Error {}

/// What a run of CFWS (comments and folding white space) held.
struct CFWSRun {
    /// Whether nothing was skipped.
    var isEmpty = true

    /// The raw text of each comment, in order (see ``AddressScanner/readComment(allowsControls:)``).
    var comments: [String] = []

    /// Whether the run held a comment.
    var hasComment: Bool {
        !comments.isEmpty
    }
}

/// Reads RFC 5322 address syntax from text.
///
/// Header syntax is delimited by ASCII code points, so the text is read as
/// Unicode scalars, never as `Character`s: a grapheme cluster can join an ASCII
/// delimiter such as `"` to a following combining mark (RFC 6532), and would
/// then no longer compare equal to it.
struct AddressScanner {
    let scalars: [Unicode.Scalar]
    var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool {
        position >= scalars.count
    }

    var current: Unicode.Scalar? {
        scalar(at: position)
    }

    func scalar(at index: Int) -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    /// Consumes `scalar` if it is next.
    mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard current == scalar else { return false }
        position += 1
        return true
    }

    /// Consumes `scalar`, which the grammar requires next.
    mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard consume(scalar) else { throw AddressSyntaxError() }
    }
}

// MARK: - White space and comments

extension AddressScanner {
    /// Skips CFWS and reports what it held.
    ///
    /// - Parameter allowsControls: Whether a comment may hold a control
    ///   character other than CR and LF, as in a display name being recovered.
    @discardableResult
    mutating func skipCFWS(allowsControls: Bool = false) throws -> CFWSRun {
        var run = CFWSRun()
        while true {
            if skipFWS() {
                run.isEmpty = false
            } else if current == "(" {
                run.comments.append(try readComment(allowsControls: allowsControls))
                run.isEmpty = false
            } else {
                return run
            }
        }
    }

    /// Skips folding white space (RFC 5322 §3.2.2): WSP, and line breaks that
    /// fold a line. Returns whether anything was skipped.
    mutating func skipFWS() -> Bool {
        let start = position
        while true {
            if let scalar = current, AddressSyntax.isWSP(scalar) {
                position += 1
            } else if let length = foldLength() {
                position += length
            } else {
                return position > start
            }
        }
    }

    /// The length of the line break at the current position if it folds the
    /// line, i.e. white space follows it: CRLF, or a bare LF as in mail stored
    /// with Unix line endings. A line break that doesn't fold is not white
    /// space, and nothing in address syntax accepts it.
    func foldLength() -> Int? {
        let lineFeed = current == "\r" ? position + 1 : position
        guard scalar(at: lineFeed) == "\n",
              let next = scalar(at: lineFeed + 1), AddressSyntax.isWSP(next) else {
            return nil
        }
        return lineFeed + 1 - position
    }

    /// Reads a comment and returns its raw text: nested comments kept with
    /// their parentheses, quoted-pairs kept as written (a look-alike of an
    /// encoded-word built from them is not one), and folds unfolded.
    ///
    /// - Parameter allowsControls: Whether a control character other than CR
    ///   and LF is read as text, as it is in a display name being recovered.
    mutating func readComment(allowsControls: Bool = false) throws -> String {
        try expect("(")
        var text: [Unicode.Scalar] = []
        var depth = 1
        while let scalar = current {
            if let length = foldLength() {
                position += length
            } else if scalar == "\\" {
                let quoted = try readQuotedPair(allowsControls: allowsControls)
                text += ["\\", quoted]
            } else {
                position += 1
                depth += scalar == "(" ? 1 : 0
                depth -= scalar == ")" ? 1 : 0
                guard depth > 0 else { return String(unicodeScalars: text) }
                let isText = scalar == "(" || scalar == ")" || AddressSyntax.isCommentText(scalar)
                guard isText || (allowsControls && AddressSyntax.isControlInText(scalar)) else {
                    throw AddressSyntaxError()
                }
                text.append(scalar)
            }
        }
        throw AddressSyntaxError()
    }

    /// Reads a quoted-pair, `\` followed by a visible character or WSP, and
    /// returns the quoted scalar. A fold between the two is removed first, as
    /// RFC 5322 §2.2.3 reads syntax after unfolding.
    mutating func readQuotedPair(allowsControls: Bool = false) throws -> Unicode.Scalar {
        try expect("\\")
        if let length = foldLength() {
            position += length
        }
        guard let scalar = current else { throw AddressSyntaxError() }
        let isQuotable = AddressSyntax.isVisible(scalar) || AddressSyntax.isWSP(scalar)
        guard isQuotable || (allowsControls && AddressSyntax.isControlInText(scalar)) else {
            throw AddressSyntaxError()
        }
        position += 1
        return scalar
    }
}

// MARK: - Words and domain literals

extension AddressScanner {
    /// Reads an atom's text, 1*atext, or returns `nil` when none starts here.
    mutating func readAtom() -> String? {
        let start = position
        while let scalar = current, AddressSyntax.isAtext(scalar) {
            position += 1
        }
        return position > start ? String(unicodeScalars: scalars[start..<position]) : nil
    }

    /// Reads a quoted-string and returns its content (RFC 5322 §3.2.4):
    /// quoted-pairs resolved, the line break of a fold removed, and white
    /// space kept.
    ///
    /// - Parameter allowsControls: Whether a control character other than CR
    ///   and LF is read as text, as it is in a display name being recovered.
    mutating func readQuotedString(allowsControls: Bool = false) throws -> String {
        try expect("\"")
        var content: [Unicode.Scalar] = []
        while let scalar = current {
            if let length = foldLength() {
                position += length
            } else if scalar == "\\" {
                content.append(try readQuotedPair(allowsControls: allowsControls))
            } else if scalar == "\"" {
                position += 1
                return String(unicodeScalars: content)
            } else {
                let isText = AddressSyntax.isQuotedText(scalar)
                guard isText || (allowsControls && AddressSyntax.isControlInText(scalar)) else {
                    throw AddressSyntaxError()
                }
                content.append(scalar)
                position += 1
            }
        }
        throw AddressSyntaxError()
    }

    /// Reads a domain literal and returns it with its brackets. Its content is
    /// kept as written, white space and (obsolete) quoted-pairs included; only
    /// the line break of a fold is removed.
    mutating func readDomainLiteral() throws -> String {
        try expect("[")
        var literal: [Unicode.Scalar] = ["["]
        while let scalar = current {
            if let length = foldLength() {
                position += length
            } else if scalar == "\\" {
                let quoted = try readQuotedPair()
                literal += ["\\", quoted]
            } else if scalar == "]" {
                position += 1
                return String(unicodeScalars: literal + ["]"])
            } else {
                guard AddressSyntax.isDomainText(scalar) else { throw AddressSyntaxError() }
                literal.append(scalar)
                position += 1
            }
        }
        throw AddressSyntaxError()
    }
}
