import Testing
import SwiftMailCore

@Suite("MailServerConfig Tests")
struct MailServerConfigTests {
    @Test("Basic configuration initialization")
    func testBasicConfig() throws {
        let config = MailServerConfig(hostname: "mail.example.com", port: 993, useSSL: true)
        #expect(config.hostname == "mail.example.com")
        #expect(config.port == 993)
        #expect(config.useSSL == true)
    }
    
    @Test("Default SSL value")
    func testDefaultSSLValue() throws {
        let config = MailServerConfig(hostname: "mail.example.com", port: 993)
        #expect(config.useSSL == true, "SSL should be enabled by default")
    }
} 