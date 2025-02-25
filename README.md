# SwiftIMAP

A Swift command-line application that demonstrates loading IMAP server credentials from a `.env` file.

## Features

- Loads IMAP server credentials from a `.env` file
- Uses the SwiftDotenv package for environment variable management
- Demonstrates secure credential handling

## Requirements

- Swift 6.0 or later
- macOS, Linux, or any platform that supports Swift

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/SwiftIMAP.git
   cd SwiftIMAP
   ```

2. Build the package:
   ```bash
   swift build
   ```

3. Run the executable:
   ```bash
   swift run
   ```

## Configuration

The application expects a `.env` file at `/Users/oliver/Developer/.env` with the following format:

```
# IMAP Server Credentials
IMAP_HOST=mail.example.com
IMAP_PORT=993
IMAP_USERNAME=your_username@example.com
IMAP_PASSWORD=your_password
```

## Running in Xcode

If you want to run the application in Xcode:

1. Open the package in Xcode:
   ```bash
   open Package.swift
   ```

2. In Xcode, select the SwiftIMAP scheme and run the application.

## Dependencies

- [SwiftDotenv](https://github.com/thebarndog/swift-dotenv) - For loading environment variables from `.env` files

## License

This project is available under the MIT license. See the LICENSE file for more info. 