public enum MailTransportSecurity: Sendable, Equatable {
    case automatic
    case implicitTLS
    case startTLS
    case plainText
}
