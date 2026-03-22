#!/usr/bin/env python3
# /// script
# dependencies = []
# ///
"""Minimal IMAP4rev1 server for integration testing.

Serves emails from a Maildir directory over IMAPS (TLS).
Supports just enough of the IMAP protocol for SwiftMail's IMAPSyncer.

Usage:
    uv run imap_server.py --port 10993 --maildir /path/to/Maildir \
        --cert server.pem --key server.key \
        --user testuser --password testpass
"""
import argparse
import asyncio
import email
import email.utils
import os
import re
import signal
import sys
from pathlib import Path


class IMAPSession:
    def __init__(self, messages, username, password):
        self.messages = messages  # list of (uid, parsed_email, raw_bytes)
        self.username = username
        self.password = password
        self.authenticated = False
        self.selected_mailbox = None
        self.tag_counter = 0

    def handle_command(self, tag, command, args):
        cmd = command.upper()
        if cmd == "CAPABILITY":
            return self._capability(tag)
        elif cmd == "LOGIN":
            return self._login(tag, args)
        elif cmd == "SELECT":
            return self._select(tag, args)
        elif cmd == "FETCH":
            return self._fetch(tag, args, uid_mode=False)
        elif cmd == "UID":
            return self._uid_command(tag, args)
        elif cmd == "LOGOUT":
            return f"* BYE IMAP server shutting down\r\n{tag} OK LOGOUT completed\r\n"
        elif cmd == "NOOP":
            return f"{tag} OK NOOP completed\r\n"
        elif cmd == "NAMESPACE":
            return f'* NAMESPACE (("" "/")) NIL NIL\r\n{tag} OK NAMESPACE completed\r\n'
        elif cmd == "LIST":
            return f'* LIST (\\HasNoChildren) "/" "INBOX"\r\n{tag} OK LIST completed\r\n'
        elif cmd == "ID":
            return f"* ID NIL\r\n{tag} OK ID completed\r\n"
        else:
            return f"{tag} BAD Unknown command {command}\r\n"

    def _capability(self, tag):
        return (
            "* CAPABILITY IMAP4rev1 AUTH=PLAIN LITERAL+ ID NAMESPACE UIDPLUS\r\n"
            f"{tag} OK CAPABILITY completed\r\n"
        )

    def _login(self, tag, args):
        # Accept any credentials — auth is not the focus of these tests
        self.authenticated = True
        return f"{tag} OK LOGIN completed\r\n"

    def _select(self, tag, args):
        if not self.authenticated:
            return f"{tag} NO Not authenticated\r\n"
        mailbox = args.strip().strip('"')
        self.selected_mailbox = mailbox
        count = len(self.messages)
        uidvalidity = 1
        uidnext = (self.messages[-1][0] + 1) if self.messages else 1
        return (
            f"* {count} EXISTS\r\n"
            f"* 0 RECENT\r\n"
            f"* OK [UIDVALIDITY {uidvalidity}] UIDs valid\r\n"
            f"* OK [UIDNEXT {uidnext}] Predicted next UID\r\n"
            f"* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n"
            f"* OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft \\*)] Flags permitted\r\n"
            f"{tag} OK [READ-WRITE] SELECT completed\r\n"
        )

    def _uid_command(self, tag, args):
        parts = args.split(None, 1)
        if not parts:
            return f"{tag} BAD Missing UID subcommand\r\n"
        subcmd = parts[0].upper()
        subargs = parts[1] if len(parts) > 1 else ""
        if subcmd == "FETCH":
            return self._fetch(tag, subargs, uid_mode=True)
        elif subcmd == "SEARCH":
            return self._uid_search(tag, subargs)
        return f"{tag} BAD Unknown UID subcommand\r\n"

    def _uid_search(self, tag, args):
        # Return all UIDs
        uids = " ".join(str(m[0]) for m in self.messages)
        return f"* SEARCH {uids}\r\n{tag} OK UID SEARCH completed\r\n"

    def _parse_sequence_set(self, seq_str, uid_mode):
        """Parse IMAP sequence set like '1:*', '1,2,3', '5:10'."""
        results = []
        for part in seq_str.split(","):
            if ":" in part:
                start_s, end_s = part.split(":", 1)
                start = int(start_s)
                if end_s == "*":
                    end = max(m[0] for m in self.messages) if uid_mode else len(self.messages)
                else:
                    end = int(end_s)
                for msg_uid, msg, raw in self.messages:
                    val = msg_uid if uid_mode else (self.messages.index((msg_uid, msg, raw)) + 1)
                    if start <= val <= end:
                        results.append((msg_uid, msg, raw))
            elif part == "*":
                if self.messages:
                    results.append(self.messages[-1])
            else:
                num = int(part)
                for msg_uid, msg, raw in self.messages:
                    val = msg_uid if uid_mode else (self.messages.index((msg_uid, msg, raw)) + 1)
                    if val == num:
                        results.append((msg_uid, msg, raw))
        return results

    def _fetch(self, tag, args, uid_mode):
        if not self.selected_mailbox:
            return f"{tag} NO No mailbox selected\r\n"

        # Parse: sequence_set (items)
        # e.g., "1:* (FLAGS UID ENVELOPE)" or "1:3 (BODY.PEEK[])"
        match = re.match(r"(\S+)\s+\((.+)\)", args)
        if not match:
            match = re.match(r"(\S+)\s+(\S+)", args)
        if not match:
            return f"{tag} BAD Invalid FETCH arguments\r\n"

        seq_str = match.group(1)
        items_str = match.group(2).upper()

        matched = self._parse_sequence_set(seq_str, uid_mode)
        response = ""

        for msg_uid, msg, raw in matched:
            seqnum = self.messages.index((msg_uid, msg, raw)) + 1
            fetch_items = []

            if "UID" in items_str or uid_mode:
                fetch_items.append(f"UID {msg_uid}")

            if "FLAGS" in items_str:
                fetch_items.append("FLAGS (\\Seen)")

            if "ENVELOPE" in items_str:
                envelope = self._build_envelope(msg)
                fetch_items.append(f"ENVELOPE {envelope}")

            if "INTERNALDATE" in items_str:
                date_str = msg.get("Date", "")
                try:
                    dt = email.utils.parsedate_to_datetime(date_str)
                    imap_date = dt.strftime("%d-%b-%Y %H:%M:%S %z")
                except Exception:
                    imap_date = "01-Jan-2025 00:00:00 +0000"
                fetch_items.append(f'INTERNALDATE "{imap_date}"')

            if "RFC822.SIZE" in items_str:
                fetch_items.append(f"RFC822.SIZE {len(raw)}")

            if "BODYSTRUCTURE" in items_str:
                bs = self._build_bodystructure(msg)
                fetch_items.append(f"BODYSTRUCTURE {bs}")

            if "BODY[]" in items_str or "BODY.PEEK[]" in items_str:
                fetch_items.append(f"BODY[] {{{len(raw)}}}\r\n".encode().decode() + raw.decode("utf-8", errors="replace"))

            # Handle BODY[HEADER] or BODY.PEEK[HEADER]
            if "BODY[HEADER]" in items_str or "BODY.PEEK[HEADER]" in items_str:
                header_end = raw.find(b"\r\n\r\n")
                if header_end == -1:
                    header_end = raw.find(b"\n\n")
                if header_end >= 0:
                    headers = raw[:header_end + 2]
                else:
                    headers = raw
                fetch_items.append(f"BODY[HEADER] {{{len(headers)}}}\r\n".encode().decode() + headers.decode("utf-8", errors="replace"))

            # Handle BODY[TEXT] or BODY.PEEK[TEXT]
            if "BODY[TEXT]" in items_str or "BODY.PEEK[TEXT]" in items_str:
                header_end = raw.find(b"\r\n\r\n")
                if header_end == -1:
                    header_end = raw.find(b"\n\n")
                if header_end >= 0:
                    body = raw[header_end + 4:]  # skip \r\n\r\n
                else:
                    body = b""
                fetch_items.append(f"BODY[TEXT] {{{len(body)}}}\r\n".encode().decode() + body.decode("utf-8", errors="replace"))

            items_joined = " ".join(fetch_items)
            response += f"* {seqnum} FETCH ({items_joined})\r\n"

        response += f"{tag} OK {'UID ' if uid_mode else ''}FETCH completed\r\n"
        return response

    def _build_envelope(self, msg):
        date = self._quote(msg.get("Date", ""))
        subject = self._quote(msg.get("Subject", ""))
        from_addr = self._build_addr_list(msg.get("From", ""))
        to_addr = self._build_addr_list(msg.get("To", ""))
        message_id = self._quote(msg.get("Message-ID", ""))
        # (date subject from sender reply-to to cc bcc in-reply-to message-id)
        return f"({date} {subject} {from_addr} {from_addr} {from_addr} {to_addr} NIL NIL NIL {message_id})"

    def _build_addr_list(self, header_val):
        if not header_val:
            return "NIL"
        name, addr = email.utils.parseaddr(header_val)
        if not addr:
            return "NIL"
        local, _, domain = addr.partition("@")
        name_q = self._quote(name) if name else "NIL"
        return f"(({name_q} NIL {self._quote(local)} {self._quote(domain)}))"

    def _build_bodystructure(self, msg):
        ct = msg.get_content_type() or "text/plain"
        maintype, _, subtype = ct.partition("/")
        charset = msg.get_content_charset() or "utf-8"
        payload = msg.get_payload(decode=True) or b""
        size = len(payload)
        lines = payload.count(b"\n")
        return f'("{maintype.upper()}" "{subtype.upper()}" ("CHARSET" "{charset.upper()}") NIL NIL "7BIT" {size} {lines})'

    def _quote(self, s):
        if s is None:
            return "NIL"
        s = s.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{s}"'


async def handle_client(reader, writer, session_factory):
    session = session_factory()
    try:
        # Brief delay before greeting to allow the client's NIO pipeline
        # to fully set up handlers (avoids race condition in plaintext mode)
        # await asyncio.sleep(0.1)

        # Send greeting
        writer.write(b"* OK IMAP test server ready\r\n")
        await writer.drain()

        buffer = b""
        while True:
            data = await reader.read(65536)
            if not data:
                break
            buffer += data

            while b"\r\n" in buffer:
                line, buffer = buffer.split(b"\r\n", 1)
                line_str = line.decode("utf-8", errors="replace")

                # Check for literal: {N}\r\n
                literal_match = re.search(r"\{(\d+)\}$", line_str)
                if literal_match:
                    literal_size = int(literal_match.group(1))
                    # Send continuation
                    writer.write(b"+ Ready for literal\r\n")
                    await writer.drain()
                    # Read literal data
                    while len(buffer) < literal_size + 2:  # +2 for trailing \r\n
                        more = await reader.read(65536)
                        if not more:
                            return
                        buffer += more
                    literal_data = buffer[:literal_size]
                    buffer = buffer[literal_size:]
                    # Skip trailing \r\n after literal
                    if buffer.startswith(b"\r\n"):
                        buffer = buffer[2:]
                    line_str = line_str[:literal_match.start()] + literal_data.decode("utf-8", errors="replace")

                # Parse tag and command
                parts = line_str.split(None, 2)
                if len(parts) < 2:
                    writer.write(b"* BAD Invalid command\r\n")
                    await writer.drain()
                    continue

                tag = parts[0]
                command = parts[1]
                cmd_args = parts[2] if len(parts) > 2 else ""

                response = session.handle_command(tag, command, cmd_args)
                writer.write(response.encode("utf-8"))
                await writer.drain()

                if command.upper() == "LOGOUT":
                    writer.close()
                    return
    except (asyncio.CancelledError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def run_server(args):
    # Load messages from Maildir
    maildir_path = Path(args.maildir)
    messages = []
    uid = 1
    for subdir in ["cur", "new"]:
        d = maildir_path / subdir
        if d.exists():
            for f in sorted(d.iterdir()):
                if f.is_file():
                    raw = f.read_bytes()
                    # Normalize line endings to \r\n for IMAP
                    if b"\r\n" not in raw:
                        raw = raw.replace(b"\n", b"\r\n")
                    msg = email.message_from_bytes(raw)
                    messages.append((uid, msg, raw))
                    uid += 1

    print(f"Loaded {len(messages)} messages from {maildir_path}", file=sys.stderr, flush=True)

    def make_session():
        return IMAPSession(messages, args.user, args.password)

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, make_session),
        host=args.host,
        port=args.port,
    )

    # Report the actual port (useful when port=0 for OS-assigned)
    actual_port = server.sockets[0].getsockname()[1]
    print(f"READY:{actual_port}", flush=True)

    # Handle shutdown
    loop = asyncio.get_event_loop()
    stop = loop.create_future()

    def handle_signal():
        if not stop.done():
            stop.set_result(None)

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, handle_signal)

    async with server:
        await stop

    server.close()
    await server.wait_closed()


def main():
    parser = argparse.ArgumentParser(description="Minimal IMAP test server")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--maildir", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    asyncio.run(run_server(args))


if __name__ == "__main__":
    main()
