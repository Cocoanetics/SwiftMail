//
//  UndefinedFolderError.swift
//  SwiftMail
//
//  Created by Oliver Drobnik on 24.03.25.
//

import Foundation

/**
 Error thrown when a standard folder is not defined.
 
 This error is thrown when attempting to access a special-use folder
 that has not been defined on the server or has not been detected yet.
 
 Call `listSpecialUseMailboxes()` first to detect special folders.
 */
public enum UndefinedFolderError: Error, CustomStringConvertible {
	/// The inbox folder is not defined
	case inbox
	/// The trash folder is not defined
	case trash
	/// The archive folder is not defined
	case archive
	/// The sent folder is not defined
	case sent
	/// The drafts folder is not defined
	case drafts
	/// The junk folder is not defined
	case junk
	
	public var description: String {
		let folderName: String
		switch self {
			case .inbox: folderName = "Inbox"
			case .trash: folderName = "Trash"
			case .archive: folderName = "Archive"
			case .sent: folderName = "Sent"
			case .drafts: folderName = "Drafts"
			case .junk: folderName = "Junk"
		}
		return "Standard folder '\(folderName)' is not defined. Call listSpecialUseMailboxes() first to detect special folders."
	}
}
