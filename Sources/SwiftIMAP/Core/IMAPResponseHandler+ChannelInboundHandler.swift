// IMAPResponseHandler+ChannelInboundHandler.swift
// Extension for IMAPResponseHandler to conform to ChannelInboundHandler

import Foundation
import os.log
@preconcurrency import NIOIMAP
import NIOIMAPCore
import NIO
import NIOConcurrencyHelpers

extension IMAPResponseHandler: ChannelInboundHandler {
	public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let response = self.unwrapInboundIn(data)
		
		// Log all responses for better visibility
		logger.notice("IMAP RESPONSE: \(String(describing: response), privacy: .public)")
		
		// Check if this is an untagged response (server greeting)
		if case .untagged(_) = response, let greetingPromise = lock.withLock({ self.greetingPromise }) {
			// Server greeting is typically an untagged OK response
			// The first response from the server is the greeting
			greetingPromise.succeed(())
		}
		
		// Process untagged responses for mailbox information during SELECT
		if case .untagged(let untaggedResponse) = response, 
			lock.withLock({ self.selectPromise != nil }), 
			let mailboxName = lock.withLock({ self.currentMailboxName }) {
			
			lock.withLock {
				if self.currentMailboxInfo == nil {
					self.currentMailboxInfo = MailboxInfo(name: mailboxName)
				}
			}
			
			// Extract mailbox information from untagged responses
			switch untaggedResponse {
				case .conditionalState(let status):
					// Handle OK responses with response text
					if case .ok(let responseText) = status {
						// Check for response codes in the response text
						if let responseCode = responseText.code {
							switch responseCode {
								case .unseen(let firstUnseen):
									lock.withLock {
										self.currentMailboxInfo?.firstUnseen = Int(firstUnseen)
									}
									
								case .uidValidity(let validity):
									// Use the BinaryInteger extension to convert UIDValidity to UInt32
									lock.withLock {
										self.currentMailboxInfo?.uidValidity = UInt32(validity)
									}
									
								case .uidNext(let next):
									// Use the BinaryInteger extension to convert UID to UInt32
									lock.withLock {
										self.currentMailboxInfo?.uidNext = UInt32(next)
									}
									
								case .permanentFlags(let flags):
									lock.withLock {
										self.currentMailboxInfo?.permanentFlags = flags.map { String(describing: $0) }
									}
									
								case .readOnly:
									lock.withLock {
										self.currentMailboxInfo?.isReadOnly = true
									}
									
								case .readWrite:
									lock.withLock {
										self.currentMailboxInfo?.isReadOnly = false
									}
									
								default:
									break
							}
						}
					}
					
				case .mailboxData(let mailboxData):
					// Extract mailbox information from mailbox data
					switch mailboxData {
						case .exists(let count):
							lock.withLock {
								self.currentMailboxInfo?.messageCount = Int(count)
							}
							
						case .recent(let count):
							lock.withLock {
								self.currentMailboxInfo?.recentCount = Int(count)
							}
							
						case .flags(let flags):
							lock.withLock {
								self.currentMailboxInfo?.availableFlags = flags.map { String(describing: $0) }
							}
							
						default:
							break
					}
					
				case .messageData(_):
					// Handle message data if needed
					break
					
				default:
					break
			}
		}
		
		// Process FETCH responses for email headers
		if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchPromise != nil }) {
			switch fetchResponse {
				case .simpleAttribute(let attribute):
					// Process the attribute directly
					processMessageAttribute(attribute, sequenceNumber: nil)
					
				case .start(let sequenceNumber):
					// Create a new email header for this sequence number
					let header = EmailHeader(sequenceNumber: Int(sequenceNumber))
					lock.withLock {
						self.emailHeaders.append(header)
					}
					
				default:
					break
			}
		} else if case .untagged(let untaggedResponse) = response, lock.withLock({ self.fetchPromise != nil }) {
			if case .messageData(_) = untaggedResponse {
			}
		}
		
		// Process FETCH responses for message parts
		if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchPartPromise != nil }) {
			switch fetchResponse {
				case .simpleAttribute(let attribute):
					if case .body(_, _) = attribute {
					}
				case .streamingBegin(let kind, _):
					if case .body(_, _) = kind {
					}
				case .streamingBytes(let data):
					// Collect the streaming body data
					lock.withLock {
						self.partData.append(Data(data.readableBytesView))
					}
				default:
					break
			}
		}
		
		// Process FETCH responses for message structure
		if case .fetch(let fetchResponse) = response, lock.withLock({ self.fetchStructurePromise != nil }) {
			switch fetchResponse {
				case .simpleAttribute(let attribute):
					if case .body(let bodyStructure, _) = attribute {
						if case .valid(let structure) = bodyStructure {
							// Store the body structure
							lock.withLock {
								self.bodyStructure = structure
							}
						}
					}
				default:
					break
			}
		}
		
		// Check if this is a tagged response that matches one of our commands
		if case .tagged(let taggedResponse) = response {
			// Handle login response
			if taggedResponse.tag == lock.withLock({ self.loginTag }) {
				if case .ok = taggedResponse.state {
					lock.withLock { self.loginPromise?.succeed(()) }
				} else {
					lock.withLock { self.loginPromise?.fail(IMAPError.loginFailed(String(describing: taggedResponse.state))) }
				}
			}
			
			// Handle select response
			if taggedResponse.tag == lock.withLock({ self.selectTag }) {
				if case .ok = taggedResponse.state {
					let (mailboxInfo, mailboxName, selectPromise) = lock.withLock { () -> (MailboxInfo?, String?, EventLoopPromise<MailboxInfo>?) in
						return (self.currentMailboxInfo, self.currentMailboxName, self.selectPromise)
					}
					
					if var mailboxInfo = mailboxInfo {
						// If we have a first unseen message but unseen count is 0,
						// calculate the unseen count as (total messages - first unseen + 1)
						if mailboxInfo.firstUnseen > 0 && mailboxInfo.unseenCount == 0 {
							mailboxInfo.unseenCount = mailboxInfo.messageCount - mailboxInfo.firstUnseen + 1
							
							// Update the current mailbox info with the modified copy
							lock.withLock {
								self.currentMailboxInfo = mailboxInfo
							}
						}
						
						selectPromise?.succeed(mailboxInfo)
					} else if let mailboxName = mailboxName {
						// If we didn't get any untagged responses with mailbox info, create a basic one
						selectPromise?.succeed(MailboxInfo(name: mailboxName))
					} else {
						selectPromise?.fail(IMAPError.selectFailed("No mailbox information available"))
					}
					
					// Reset for next select
					lock.withLock {
						self.currentMailboxName = nil
						self.currentMailboxInfo = nil
					}
				} else {
					lock.withLock {
						self.selectPromise?.fail(IMAPError.selectFailed(String(describing: taggedResponse.state))) }
				}
			}
			
			// Handle logout response
			if taggedResponse.tag == lock.withLock({ self.logoutTag }) {
				if case .ok = taggedResponse.state {
					lock.withLock { self.logoutPromise?.succeed(()) }
				} else {
					lock.withLock { self.logoutPromise?.fail(IMAPError.logoutFailed(String(describing: taggedResponse.state))) }
				}
			}
			
			// Handle fetch response
			if taggedResponse.tag == lock.withLock({ self.fetchTag }) {
				if case .ok = taggedResponse.state {
					let headers = lock.withLock { () -> [EmailHeader] in
						let headers = self.emailHeaders
						self.emailHeaders.removeAll()
						return headers
					}
					lock.withLock { self.fetchPromise?.succeed(headers) }
				} else {
					lock.withLock { 
						self.fetchPromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
						self.emailHeaders.removeAll()
					}
				}
			}
			
			// Handle fetch part response
			if taggedResponse.tag == lock.withLock({ self.fetchPartTag }) {
				if case .ok = taggedResponse.state {
					let partData = lock.withLock { () -> Data in
						let data = self.partData
						self.partData = Data()
						return data
					}
					lock.withLock { self.fetchPartPromise?.succeed(partData) }
				} else {
					lock.withLock { 
						self.fetchPartPromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
						self.partData = Data()
					}
				}
			}
			
			// Handle fetch structure response
			if taggedResponse.tag == lock.withLock({ self.fetchStructureTag }) {
				if case .ok = taggedResponse.state {
					let structure = lock.withLock { () -> BodyStructure? in
						let structure = self.bodyStructure
						self.bodyStructure = nil
						return structure
					}
					
					if let structure = structure {
						lock.withLock { self.fetchStructurePromise?.succeed(structure) }
					} else {
						lock.withLock { self.fetchStructurePromise?.fail(IMAPError.fetchFailed("No body structure found")) }
					}
				} else {
					lock.withLock { 
						self.fetchStructurePromise?.fail(IMAPError.fetchFailed(String(describing: taggedResponse.state)))
						self.bodyStructure = nil
					}
				}
			}
		}
	}
	
	public func errorCaught(context: ChannelHandlerContext, error: Error) {
		// Fail all pending promises
		lock.withLock {
			self.greetingPromise?.fail(error)
			self.loginPromise?.fail(error)
			self.selectPromise?.fail(error)
			self.logoutPromise?.fail(error)
			self.fetchPromise?.fail(error)
			self.fetchPartPromise?.fail(error)
			self.fetchStructurePromise?.fail(error)
		}
		
		context.close(promise: nil)
	}
} 
