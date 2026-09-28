// AddressPhrase.swift
// Display-name text from the words of a phrase (RFC 5322 §3.2.5) and RFC 2047 encoded-words.

import Foundation

/// Builds the display-name text that the words of a phrase stand for.
///
/// - CFWS between two words reads as one space (RFC 5322 §3.2.2), however much
///   white space and however many comments it holds. Words with nothing between
///   them join directly: `"John"Doe` is `JohnDoe`.
/// - An atom that is a whole encoded-word is decoded when white space or a
///   comment sets it off from the words on both sides, as RFC 2047 §5 requires.
///   Next to another word, as in `=?UTF-8?Q?John?="Doe"`, it is literal text, and
///   so is anything inside a quoted-string.
/// - Between two decoded encoded-words, white space is dropped (RFC 2047 §6.2)
///   and their bytes are decoded together, so a character split across them
///   survives. A comment between them still reads as a space.
enum AddressPhrase {
    /// The display-name text of a phrase's words.
    static func text(of tokens: [PhraseToken]) -> String {
        var text = ""
        var encodedRun: [String] = []
        for (index, token) in tokens.enumerated() {
            let isEncoded = isDecodableEncodedWord(tokens, at: index)
            if isEncoded, !encodedRun.isEmpty, !token.separator.hasComment {
                encodedRun.append(token.text)
                continue
            }
            text += decoded(encodedRun)
            encodedRun = []
            if index > 0, !token.separator.isEmpty {
                text += " "
            }
            if isEncoded {
                encodedRun = [token.text]
            } else {
                text += token.text
            }
        }
        return text + decoded(encodedRun)
    }

    /// The text of a comment used as a display name, from its raw text (see
    /// ``AddressScanner/readComment(allowsControls:)``): white space collapsed
    /// to single spaces and trimmed, quoted-pairs resolved, and encoded-words
    /// decoded where RFC 2047 §5 allows them in a comment, set off by white
    /// space or a parenthesis. A word holding a quoted-pair is never one.
    static func commentText(_ raw: String) -> String {
        var text = ""
        var encodedRun: [String] = []
        var hasPendingSpace = false

        /// Writes out the pending encoded-words, then the space before the next piece.
        func startPiece() {
            text += decoded(encodedRun)
            encodedRun = []
            if hasPendingSpace && !text.isEmpty {
                text += " "
            }
        }

        for piece in commentPieces(raw) {
            switch piece {
                case .space:
                    hasPendingSpace = true
                    continue
                case .word(let word) where !word.contains("\\") && EncodedWord.isEncodedWord(word):
                    // White space between two encoded-words is not displayed (RFC 2047 §6.2).
                    if encodedRun.isEmpty {
                        startPiece()
                    }
                    encodedRun.append(word)
                case .word(let word):
                    startPiece()
                    text += unescapingQuotedPairs(word)
                case .parenthesis(let parenthesis):
                    startPiece()
                    text.unicodeScalars.append(parenthesis)
            }
            hasPendingSpace = false
        }
        return text + decoded(encodedRun)
    }

    /// A piece of a comment's raw text.
    private enum CommentPiece {
        case space
        case parenthesis(Unicode.Scalar)
        case word(String)
    }

    /// Splits a comment's raw text into white space, unescaped parentheses,
    /// and the words between them, quoted-pairs kept.
    private static func commentPieces(_ raw: String) -> [CommentPiece] {
        var pieces: [CommentPiece] = []
        var word: [Unicode.Scalar] = []
        var isEscaped = false
        func endWord() {
            if !word.isEmpty {
                pieces.append(.word(String(unicodeScalars: word)))
                word = []
            }
        }
        for scalar in raw.unicodeScalars {
            if isEscaped || scalar == "\\" {
                isEscaped = !isEscaped
                word.append(scalar)
            } else if AddressSyntax.isWSP(scalar) {
                endWord()
                pieces.append(.space)
            } else if scalar == "(" || scalar == ")" {
                endWord()
                pieces.append(.parenthesis(scalar))
            } else {
                word.append(scalar)
            }
        }
        endWord()
        return pieces
    }

    /// `word` with each quoted-pair replaced by the character it quotes.
    private static func unescapingQuotedPairs(_ word: String) -> String {
        var text = String.UnicodeScalarView()
        var isEscaped = false
        for scalar in word.unicodeScalars {
            if !isEscaped && scalar == "\\" {
                isEscaped = true
            } else {
                text.append(scalar)
                isEscaped = false
            }
        }
        return String(text)
    }

    /// Whether the word at `index` is an encoded-word that RFC 2047 lets a
    /// reader decode: an atom of encoded-word syntax with CFWS, or the edge of
    /// the phrase, on both sides.
    private static func isDecodableEncodedWord(_ tokens: [PhraseToken], at index: Int) -> Bool {
        let token = tokens[index]
        guard token.kind == .atom, EncodedWord.isEncodedWord(token.text) else { return false }
        let isSetOffBefore = index == 0 || !token.separator.isEmpty
        let isSetOffAfter = index == tokens.count - 1 || !tokens[index + 1].separator.isEmpty
        return isSetOffBefore && isSetOffAfter
    }

    /// Decodes adjacent encoded-words as one run: `decodeMIMEHeader()` drops the
    /// white space between them and joins the bytes of words in the same
    /// charset. A word that doesn't decode stays as written.
    static func decoded(_ words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        return words.joined(separator: " ").decodeMIMEHeader()
    }
}

/// A word of a phrase and the CFWS before it.
struct PhraseToken {
    enum Kind {
        case atom
        case quoted
        case dot
    }

    let kind: Kind

    /// The word's text: an atom as written, a quoted-string's content, or ".".
    let text: String

    /// The CFWS before the word.
    let separator: CFWSRun
}

/// RFC 2047 encoded-word syntax: `=?charset?encoding?encoded-text?=`.
enum EncodedWord {
    /// Whether `text` is exactly one encoded-word (RFC 2047 §2): a charset name
    /// (which RFC 2231 §5 lets carry a `*language` suffix), `B` or `Q`, and at
    /// least one character of encoded text, all printable ASCII other than `?`.
    static func isEncodedWord(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 9, scalars.starts(with: ["=", "?"]), Array(scalars.suffix(2)) == ["?", "="] else {
            return false
        }
        let inner = scalars[2..<(scalars.count - 2)]
        let parts = inner.split(separator: "?", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].first != "*", !parts[0].isEmpty, parts[1].count == 1,
              let encoding = parts[1].first, "BbQq".unicodeScalars.contains(encoding), !parts[2].isEmpty else {
            return false
        }
        return inner.allSatisfy { $0.isASCII && AddressSyntax.isVisible($0) }
    }
}
