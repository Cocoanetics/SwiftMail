import Foundation
import NIOCore
import Logging

/// Handler for SMTP LOGIN authentication
final class LoginAuthHandler: BaseSMTPHandler<AuthResult>, @unchecked Sendable {
    /// State machine to handle the authentication process
    private var stateMachine: AuthHandlerStateMachine
    
    /// Required initializer
    required init(commandTag: String?, promise: EventLoopPromise<AuthResult>) {
        // Create state machine with default values - these will be set in the command
        self.stateMachine = AuthHandlerStateMachine(
            method: AuthMethod.login,
            username: "",
            password: ""
        )
        super.init(commandTag: commandTag, promise: promise)
    }
    
    /// Custom initializer with command parameters
	convenience init(commandTag: String?, promise: EventLoopPromise<AuthResult>,
                         command: LoginAuthCommand) {
        self.init(commandTag: commandTag, promise: promise)
        // Update the state machine with the actual credentials from the command
        self.stateMachine = AuthHandlerStateMachine(
            method: AuthMethod.login, 
            username: command.username, 
            password: command.password
        )
    }
    
    /// Process a response line from the server
    /// - Parameter response: The response line to process
    /// - Returns: Whether the handler is complete
    override func processResponse(_ response: SMTPResponse) -> Bool {
        
        // Use the state machine to process the response
        let result = stateMachine.processResponse(response) { [weak self] credential in
            // This closure is called when we need to send a credential
            guard let self = self, let context = self.context else {
                self?.promise.fail(SMTPError.connectionFailed("Channel context is nil"))
                return
            }
            
            // Encode the credential in base64
            let base64Credential = Data(credential.utf8).base64EncodedString()
            
            // Create a buffer and write it out
            var buffer = context.channel.allocator.buffer(capacity: base64Credential.utf8.count + 2)
            buffer.writeString(base64Credential + "\r\n")
            
            // Write the credential to the channel
            context.writeAndFlush(NIOAny(buffer), promise: nil)
        }
        
        // If the authentication process is complete, fulfill the promise
        if result.isComplete, let authResult = result.result {
            promise.succeed(authResult)
            return true
        }
        
        return false // Not yet complete
    }
    
    // Current channel context for sending responses
    private var context: ChannelHandlerContext?
    
    /// Store the context when added to the pipeline
	func channelRegistered(context: ChannelHandlerContext) {
        self.context = context
        context.fireChannelRegistered()
    }
    
    /// Store the context when handler is added to the pipeline (alternative to channelRegistered)
	func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }
    
    /// Store the context when the channel becomes active
	func channelActive(context: ChannelHandlerContext) {
        self.context = context
        context.fireChannelActive()
    }
    
    /// Clear the context when removed from the pipeline
	func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }
} 
