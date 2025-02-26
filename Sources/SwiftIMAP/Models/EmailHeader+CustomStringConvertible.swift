import Foundation

extension EmailHeader: CustomStringConvertible {
    public var description: String {
        return """
        Email #\(sequenceNumber)
        Subject: \(subject)
        From: \(from)
        Date: \(date)
        """
    }
} 