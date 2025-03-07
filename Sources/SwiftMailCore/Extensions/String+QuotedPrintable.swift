import Foundation

extension String {
    public func quotedPrintableEncoded() -> String {
        var encoded = ""
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!*+-/=_ ")

        for char in utf8 {
            if allowedCharacters.contains(UnicodeScalar(char)) && char != UInt8(ascii: " ") {
                encoded.append(Character(UnicodeScalar(char)))
            } else if char == UInt8(ascii: " ") {
                encoded.append("_")
            } else {
                encoded.append(String(format: "=%02X", char))
            }
        }

        return encoded
    }
} 