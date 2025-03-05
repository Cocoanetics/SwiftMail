import Foundation
import NIOCore
import Logging

/// Handler for SMTP LOGIN authentication
public class LoginAuthHandler: BaseSMTPHandler<AuthResult> {
    /// State machine to handle the authentication process
    private var stateMachine: AuthHandlerStateMachine
    
    /// Logger for this handler
    private let logger = Logger(label: "com.cocoanetics.SwiftSMTP.LoginAuthHandler")
    
    /// Required initializer
    public required init(commandTag: String?, promise: EventLoopPromise<AuthResult>) {
        // Create state machine with default values - these will be set in the command
        self.stateMachine = AuthHandlerStateMachine(
            method: AuthMethod.login,
            username: "",
            password: ""
        )
        super.init(commandTag: commandTag, promise: promise)
    }
    
    /// Custom initializer with command parameters
    public convenience init(commandTag: String?, promise: EventLoopPromise<AuthResult>, 
                         command: LoginAuthCommand) {
        self.init(commandTag: commandTag, promise: promise)
        // Update the state machine with the actual credentials from the command
        self.stateMachine = AuthHandlerStateMachine(
            method: AuthMethod.login, 
            username: command.username, 
            password: command.password
        )
        logger.debug("Initialized LoginAuthHandler with username: \(command.username)")
    }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override public func processResponse(_ response: SMTPResponse) -> Bool {
        logger.debug("Processing SMTP response: \(response.code) \(response.message)")
        
        // Use the state machine to process the response
        let result = stateMachine.processResponse(response) { [weak self] credential in
            // This closure is called when we need to send a credential
            guard let self = self, let context = self.context else {
                self?.logger.error("Cannot send credential: Channel context is nil")
                self?.promise.fail(SMTPError.connectionFailed("Channel context is nil"))
                return
            }
            
            // Encode the credential in base64
            let base64Credential = Data(credential.utf8).base64EncodedString()
            logger.debug("Sending credential (base64 encoded)")
            
            // Create a buffer and write it out
            var buffer = context.channel.allocator.buffer(capacity: base64Credential.utf8.count + 2)
            buffer.writeString(base64Credential + "\r\n")
            
            // Write the credential to the channel
            context.writeAndFlush(NIOAny(buffer), promise: nil)
        }
        
        // If the authentication process is complete, fulfill the promise
        if result.isComplete, let authResult = result.result {
            if authResult.success {
                logger.info("LOGIN authentication succeeded")
            } else {
                logger.warning("LOGIN authentication failed: \(authResult.errorMessage ?? "Unknown error")")
            }
            promise.succeed(authResult)
            return true
        }
        
        return false // Not yet complete
    }
    
    // Current channel context for sending responses
    private var context: ChannelHandlerContext?
    
    /// Store the context when added to the pipeline
    public func channelRegistered(context: ChannelHandlerContext) {
        logger.debug("LoginAuthHandler registered in channel")
        self.context = context
        context.fireChannelRegistered()
    }
    
    /// Store the context when handler is added to the pipeline (alternative to channelRegistered)
    public func handlerAdded(context: ChannelHandlerContext) {
        logger.debug("LoginAuthHandler added to channel")
        self.context = context
    }
    
    /// Store the context when the channel becomes active
    public func channelActive(context: ChannelHandlerContext) {
        logger.debug("LoginAuthHandler channel became active")
        self.context = context
        context.fireChannelActive()
    }
    
    /// Clear the context when removed from the pipeline
    public func handlerRemoved(context: ChannelHandlerContext) {
        logger.debug("LoginAuthHandler removed from channel")
        self.context = nil
    }
} 