// EnclosingMultipart.swift
// A multipart body that encloses a message part.

import Foundation

/// A multipart body (RFC 2046 section 5.1) that encloses a ``MessagePart``.
///
/// Multipart bodies have no section of their own to fetch, so the flat part list
/// does not show them; this records one for the parts inside it.
public struct EnclosingMultipart: Sendable, Hashable, Codable {
    /// Where the multipart sits: the section path its children are numbered
    /// under. Empty for a message's top-level body; for the body of an attached
    /// message (`message/rfc822`), that part's section. Its children are the
    /// parts whose sections continue this path with one more number.
    public let path: [Int]

    /// The multipart subtype, lowercased: `mixed`, `alternative`, `related`, ...
    public let subtype: String

    /// - Parameters:
    ///   - path: The section path the multipart's children are numbered under
    ///   - subtype: The multipart subtype; stored lowercased
    public init(path: [Int], subtype: String) {
        self.path = path
        self.subtype = subtype.lowercased()
    }
}

extension Array where Element == EnclosingMultipart {
    /// The multiparts inside the part at `prefix`, numbered from that part as
    /// the new root: the ones outside it are dropped, and `prefix` is removed
    /// from the paths of the rest.
    func rebased(onto prefix: [Int]) -> [EnclosingMultipart] {
        compactMap { multipart -> EnclosingMultipart? in
            guard multipart.path.starts(with: prefix) else { return nil }
            return EnclosingMultipart(path: [Int](multipart.path.dropFirst(prefix.count)), subtype: multipart.subtype)
        }
    }
}
