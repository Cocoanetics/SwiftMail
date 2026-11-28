// SMTPServer+TransportMode.swift
// Which transport an SMTP connection uses, and when STARTTLS is required.

import Foundation

extension SMTPServer {
    static func resolveTransportMode(
        port: Int,
        transportSecurity: MailTransportSecurity
    ) -> SMTPTransportMode {
        switch transportSecurity {
            case .automatic:
                switch port {
                    case 465:
                        return .implicitTLS
                    case 587:
                        return .startTLSIfAvailable
                    default:
                        return .plainText
                }
            case .implicitTLS:
                return .implicitTLS
            case .startTLS:
                return .startTLSRequired
            case .plainText:
                return .plainText
        }
    }

    static func requiresSTARTTLSUpgrade(
        transportMode: SMTPTransportMode,
        capabilities: [String]
    ) -> Bool {
        switch transportMode {
            case .startTLSIfAvailable, .startTLSRequired:
                return capabilities.contains("STARTTLS")
            case .implicitTLS, .plainText:
                return false
        }
    }

    static func requiresMissingSTARTTLSError(
        transportMode: SMTPTransportMode,
        capabilities: [String]
    ) -> Bool {
        transportMode == .startTLSRequired && !capabilities.contains("STARTTLS")
    }
}
