import Foundation
import Logging
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import OrderedCollections

/**
 An actor that represents a connection to an IMAP server.

 Use this class to establish and manage connections to IMAP servers, perform authentication,
 and execute IMAP commands. The class handles connection lifecycle, command execution,
 and maintains server state.

 Example:
 ```swift
 let server = IMAPServer(host: "imap.example.com", port: 993)
 try await server.connect()
 try await server.login(username: "user@example.com", password: "password")
 ```

 - Note: All operations are logged using the Swift Logging package. To view logs in Console.app:
 1. Open Console.app
 2. Search for "process:com.cocoanetics.SwiftMail"
 3. Adjust the "Action" menu to show Debug and Info messages
 */
/// Maximum number of identifiers per IMAP FETCH command when chunking large sets.
let defaultFetchChunkSize = 50

public actor IMAPServer {
    // MARK: - Properties

    /** The hostname of the IMAP server */
    let host: String

    /** The port number of the IMAP server */
    let port: Int

    /// Explicit TLS preference. `.automatic` infers from the standard IMAP ports.
    let transportSecurity: MailTransportSecurity

    /// Certificate verification preference used by all TLS transports for this server.
    let certificateVerificationPolicy: MailCertificateVerificationPolicy

    /// Lowest TLS version any transport for this server may negotiate.
    let minimumTLSVersion: MailTLSMinimumVersion

    /// Maximum number of bytes the IMAP response parser may buffer before failing.
    /// Large SEARCH/FETCH responses from dense mailboxes can exceed a small buffer
    /// and surface as `PayloadTooLargeError`; raise this for very large mailboxes.
    let responseBufferLimit: Int

    /// Bounds the response parser enforces against a hostile or malfunctioning server.
    let parserLimits: IMAPParserLimits

    /** The event loop group for handling asynchronous operations */
    let group: EventLoopGroup

    /// Primary connection used for non-IDLE commands.
    let primaryConnection: IMAPConnection

    /// Spawned IDLE connections keyed by session ID.
    var idleConnections: [UUID: IdleConnection] = [:]

    /// User-managed named connections keyed by requested name.
    var namedConnections: [String: NamedConnection] = [:]

    /// Waiters for named connections currently being created.
    var pendingNamedConnectionWaiters: [String: [CheckedContinuation<IMAPNamedConnection, any Error>]] = [:]

    /// Authentication configuration for spawning new connections.
    var authentication: Authentication?

    /** The list of all mailboxes with their attributes */
    public private(set) var mailboxes: [Mailbox.Info] = []

    /** Special folders - mailboxes with SPECIAL-USE attributes */
    public private(set) var specialMailboxes: [Mailbox.Info] = []

    /// Namespaces discovered from the server
    public internal(set) var namespaces: NamespaceResponse?

    /// Capabilities reported by the primary connection.
    var capabilities: Set<NIOIMAPCore.Capability> {
        primaryConnection.capabilitiesSnapshot
    }

    /// Whether the primary connection advertised UIDPLUS.
    public var supportsUIDPlus: Bool {
        capabilities.contains(.uidPlus)
    }

    var certificatePolicyForTesting: MailCertificateVerificationPolicy {
        primaryConnection.certificateVerificationPolicyForTesting
    }

    /**
     Logger for IMAP operations
     To view these logs in Console.app:
     1. Open Console.app
     2. In the search field, type "process:com.cocoanetics.SwiftIMAP"
     3. You may need to adjust the "Action" menu to show "Include Debug Messages" and "Include Info Messages"
     */
    let logger: Logging.Logger

    struct IdleConnection {
        let mailbox: String
        let connection: IMAPConnection
        /// The session's private EventLoopGroup; shut down as the final step of teardown.
        let idleGroup: EventLoopGroup
        /// Set once the resilient cycle starts. Server-side teardown must cancel the
        /// cycle task before touching the connection — the runner is self-healing, so
        /// a socket that merely closes underneath it is treated as a dropped
        /// connection and re-dialed.
        var lifecycle: IMAPIdleSessionLifecycle?
        var cycleTask: Task<Void, Never>?
    }

    struct NamedConnection {
        let connection: IMAPConnection
        let handle: IMAPNamedConnection
    }

    enum Authentication {
        case login(username: String, password: String)
        case plain(username: String, password: String)
        case xoauth2(email: String, accessTokenProvider: @Sendable () async throws -> String)

        func authenticate(on connection: IMAPConnection) async throws {
            switch self {
                case .login(let username, let password):
                    try await connection.login(username: username, password: password)
                case .plain(let username, let password):
                    try await connection.authenticatePlain(username: username, password: password)
                case .xoauth2(let email, let accessTokenProvider):
                    let accessToken = try await accessTokenProvider()
                    try await connection.authenticateXOAUTH2(email: email, accessToken: accessToken)
            }
        }
    }

    // MARK: - Initialization

    /// The default IMAP response parser buffer limit (1 MB).
    ///
    /// Large SEARCH responses can contain thousands of message IDs; 1 MB keeps
    /// typical mailboxes working without an unbounded buffer. Callers indexing
    /// very large or dense mailboxes can pass a larger value to the initializer.
    public static let defaultResponseBufferLimit = 1024 * 1024

    /**
     Initialize a new IMAP server connection

     - Parameters:
     - host: The hostname of the IMAP server
     - port: The port number of the IMAP server (typically 993 for SSL)
     - transportSecurity: The transport security policy to use. `.automatic` infers from standard IMAP
     ports; explicit values override that inference.
     - certificateVerificationPolicy: The certificate verification policy to use for TLS connections.
     - minimumTLSVersion: The lowest TLS version any transport may negotiate. Defaults to
     ``MailTLSMinimumVersion/tlsv12``, the lowest version RFC 8996 still permits. Pass
     ``MailTLSMinimumVersion/tlsv13`` when every server you talk to supports it, which makes
     a downgrade impossible regardless of what the server offers.
     - numberOfThreads: The number of threads to use for the event loop group
     - parserLimits: Bounds the response parser enforces against a hostile or malfunctioning
     server. Defaults to ``IMAPParserLimits/default``, which leaves body size and attribute
     count unbounded — the behaviour before this parameter existed.
     - responseBufferLimit: Maximum bytes the IMAP response parser may buffer
     before failing with `PayloadTooLargeError`. Defaults to
     ``IMAPServer/defaultResponseBufferLimit`` (1 MB), which handles large SEARCH
     responses containing thousands of message IDs. Raise it for very dense
     mailboxes whose SEARCH/FETCH responses exceed 1 MB. Must be greater than 0.

     - Precondition: `responseBufferLimit > 0` — a non-positive limit would make
     every response exceed the buffer and fail with `PayloadTooLargeError`.
     */
    public init(
        host: String,
        port: Int,
        transportSecurity: MailTransportSecurity = .automatic,
        certificateVerificationPolicy: MailCertificateVerificationPolicy = .fullVerification,
        minimumTLSVersion: MailTLSMinimumVersion = .tlsv12,
        numberOfThreads: Int = 1,
        responseBufferLimit: Int = IMAPServer.defaultResponseBufferLimit,
        parserLimits: IMAPParserLimits = .default
    ) {
        precondition(responseBufferLimit > 0, "responseBufferLimit must be greater than 0 bytes")
        self.host = host
        self.port = port
        self.transportSecurity = transportSecurity
        self.certificateVerificationPolicy = certificateVerificationPolicy
        self.minimumTLSVersion = minimumTLSVersion
        self.responseBufferLimit = responseBufferLimit
        self.parserLimits = parserLimits
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)

        // Initialize loggers
        self.logger = Logging.Logger(label: "com.cocoanetics.SwiftMail.IMAPServer")

        let primaryLoggerLabel = "com.cocoanetics.SwiftMail.IMAPServer"
        let outboundLabel = "com.cocoanetics.SwiftMail.IMAP_OUT"
        let inboundLabel = "com.cocoanetics.SwiftMail.IMAP_IN"
        self.primaryConnection = IMAPConnection(
            host: host,
            port: port,
            transportSecurity: transportSecurity,
            certificateVerificationPolicy: certificateVerificationPolicy,
            minimumTLSVersion: minimumTLSVersion,
            group: group,
            loggerLabel: primaryLoggerLabel,
            outboundLabel: outboundLabel,
            inboundLabel: inboundLabel,
            connectionID: "primary",
            connectionRole: "primary",
            responseBufferLimit: responseBufferLimit,
            parserLimits: parserLimits
        )
    }

    public init(
        host: String,
        port: Int,
        useTLS: Bool?,
        numberOfThreads: Int = 1,
        responseBufferLimit: Int = IMAPServer.defaultResponseBufferLimit
    ) {
        self.init(
            host: host,
            port: port,
            transportSecurity: Self.resolveLegacyTransportSecurity(port: port, useTLS: useTLS),
            certificateVerificationPolicy: .fullVerification,
            numberOfThreads: numberOfThreads,
            responseBufferLimit: responseBufferLimit
        )
    }

    private static func resolveLegacyTransportSecurity(port: Int, useTLS: Bool?) -> MailTransportSecurity {
        guard let useTLS else {
            return .automatic
        }

        if useTLS {
            return port == 143 ? .startTLS : .implicitTLS
        }

        return .plainText
    }

    #if DEBUG
    /// Test-only access to the response buffer limit configured on the primary connection.
    var primaryResponseBufferLimitForTesting: Int {
        primaryConnection.responseBufferLimit
    }
    #endif

    deinit {
        // Same non-blocking pattern as SMTPServer.deinit. The callback form needs
        // neither a Task nor an actor hop: the previous @MainActor task variant
        // quietly serialized every shutdown through the main actor and never ran at
        // all in processes that do not drain the main queue.
        group.shutdownGracefully { _ in }
    }

    // MARK: - Mailbox State (used by helpers in extensions)

    /// Replace the cached mailbox listing. Used by mailbox-listing extensions.
    func updateMailboxes(_ value: [Mailbox.Info]) {
        self.mailboxes = value
    }

    /// Replace the cached special-use mailbox listing. Used by special-use extensions.
    func updateSpecialMailboxes(_ value: [Mailbox.Info]) {
        self.specialMailboxes = value
    }

    /// Reset cached mailbox state when closing all connections.
    func clearMailboxState() {
        self.namespaces = nil
        self.mailboxes = []
        self.specialMailboxes = []
    }
}
