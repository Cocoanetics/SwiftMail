import Foundation

extension MessageInfo: CustomStringConvertible {
    public var description: String {
        var result = ""

        if let from {
            result += "From: \(from)\n"
        }

        if let subject {
            result += "Subject: \(subject)\n"
        }

        if let date {
            result += "Date: \(date.formattedForDisplay())"
        }

        if !parts.isEmpty {
            result += "\n\nParts:"
            for part in parts {
                result += "\n- \(part.section): \(part.contentType)"
                if let filename = part.filename {
                    result += " (\(filename))"
                }
            }
        }

        return result
    }
}
