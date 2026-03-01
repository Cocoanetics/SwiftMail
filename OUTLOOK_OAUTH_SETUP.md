# Outlook XOAUTH2 Setup for SwiftIMAPCLI

## Current status (important)
`SwiftIMAPCLI` currently authenticates via `server.login(username:password:)` only (LOGIN command).
It does **not** yet read `IMAP_AUTH_METHOD` / `IMAP_ACCESS_TOKEN` and does not call `authenticateXOAUTH2(...)`.

Code references:
- `Demos/SwiftIMAPCLI/main.swift` (reads `IMAP_PASSWORD`, then calls `server.login(...)`)
- `Sources/SwiftMail/IMAP/IMAPServer.swift` (has `authenticateXOAUTH2(email:accessToken:)` API available)

## Token source
Use Microsoft Entra ID (Azure AD) OAuth2 for the Outlook account and request an access token for IMAP:
- Scope: `https://outlook.office365.com/IMAP.AccessAsUser.All`
- Also typically include: `offline_access openid profile email`

(For SMTP send via OAuth2, also request `https://outlook.office365.com/SMTP.Send`.)

## Environment variables
Add/use these in `.env.outlook`:

```env
IMAP_AUTH_METHOD=XOAUTH2
IMAP_ACCESS_TOKEN=<short-lived OAuth2 access token>
IMAP_USERNAME=oliver.drobnik@outlook.com
IMAP_HOST=outlook.office365.com
IMAP_PORT=993
```

## Command template to run (after CLI XOAUTH2 wiring)

```bash
cp .env.outlook .env
swift run SwiftIMAPCLI list --mailbox INBOX
```

## Minimal CLI wiring needed
In `withServer(...)` and `Idle.run()` in `Demos/SwiftIMAPCLI/main.swift`:
1. Read `IMAP_AUTH_METHOD`.
2. If `XOAUTH2`, read `IMAP_ACCESS_TOKEN` and call:
   - `try await server.authenticateXOAUTH2(email: username, accessToken: accessToken)`
3. Else keep existing `server.login(username:password:)` path.

After that wiring, the command template above will run against Outlook Modern Auth.
