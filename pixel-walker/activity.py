"""Read only subagent activity from Zeron's authenticated loopback IPC.

No transcript requests, external network destinations, writes, or third-party modules.
The IPC credential stays in memory and is never included in the output.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time

LIMIT = 8 * 1024 * 1024


class LocalActivity:
    def __init__(self):
        data = Path(__file__).resolve().parents[2]
        token = (data / "ipc-token").read_text().strip()
        if not token or any(c in token for c in "\r\n"):
            raise ValueError("Invalid local IPC credential")
        port = int(os.environ.get("ZERON_IPC_PORT", "27654"))
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"Authorization: Bearer {token}\r\n\r\n")
        self.sock.sendall(request.encode())
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError("Local IPC closed during handshake")
            self.buffer += chunk
            if len(self.buffer) > 32768:
                raise ValueError("Invalid IPC handshake")
        header, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if not header.startswith(b"HTTP/1.1 101 ") or accept.lower().encode() not in header.lower():
            self.sock.close()
            raise ValueError("Local IPC refused the connection")

    def take(self, length):
        if length > LIMIT:
            raise ValueError("IPC response too large")
        while len(self.buffer) < length:
            chunk = self.sock.recv(min(65536, length - len(self.buffer)))
            if not chunk:
                raise OSError("Local IPC closed")
            self.buffer += chunk
        result, self.buffer = self.buffer[:length], self.buffer[length:]
        return result

    def send(self, payload, opcode=1):
        payload = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", length)
        self.sock.sendall(header + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))

    def receive(self):
        chunks = bytearray()
        while True:
            a, b = self.take(2)
            length = b & 127
            if length == 126:
                length = struct.unpack("!H", self.take(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.take(8))[0]
            mask = self.take(4) if b & 128 else None
            payload = self.take(length)
            if mask:
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
            opcode = a & 15
            if opcode == 8:
                raise OSError("Local IPC closed")
            if opcode == 9:
                self.send(payload, 10)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1):
                raise ValueError("Unexpected IPC frame")
            chunks.extend(payload)
            if len(chunks) > LIMIT:
                raise ValueError("IPC response too large")
            if a & 128:
                return chunks.decode()

    def snapshots(self):
        # These are the same read-only streams used by Zeron's sidebar.
        for number, method in ((1, "WatchSessions"), (2, "WatchChats")):
            self.send({"id": number, "method": method, "params": {}})
        found = {}
        deadline = time.monotonic() + 5
        try:
            while len(found) < 2 and time.monotonic() < deadline:
                for line in self.receive().splitlines():
                    frame = json.loads(line)
                    number = frame.get("id")
                    if number not in (1, 2):
                        continue
                    if frame.get("err"):
                        raise ValueError("Local activity feed unavailable")
                    if "item" in frame:
                        found[number] = frame["item"]
            if len(found) != 2:
                raise TimeoutError("Local activity feed timed out")
            return found[1], found[2]
        finally:
            for number in (1, 2):
                try:
                    self.send({"id": number, "cancel": True})
                except OSError:
                    pass
            self.sock.close()


def active_subagents(sessions, chats, parent, now=None):
    now = time.time() if now is None else now
    latest = {}
    owners = {c["id"]: c.get("deviceId") for c in chats if c.get("id")}
    for row in sessions:
        try:
            updated = datetime.fromisoformat(row["updatedAt"].replace("Z", "+00:00")).timestamp()
            if not -5 <= now - updated <= 45:
                continue
            chat = row["chatId"]
            if owners.get(chat) and row.get("deviceId") != owners[chat]:
                continue
            if chat not in latest or updated > latest[chat][0]:
                latest[chat] = (updated, row)
        except (KeyError, TypeError, ValueError):
            continue
    active = []
    current = latest.get(parent, (0, {}))[1]
    native = current.get("runningSubagents", 0)
    if isinstance(native, int) and 0 <= native <= 256:
        active.extend(f"{parent}/native/{i}" for i in range(native))
    for chat in chats:
        if chat.get("parentChatId") != parent or chat.get("childKind") != "subagent" or chat.get("archived"):
            continue
        row = latest.get(chat.get("id"), (0, {}))[1]
        if row.get("status") == "working":
            active.append(chat["id"])
    return sorted(set(active))


if __name__ == "__main__":
    try:
        sessions, chats = LocalActivity().snapshots()
        answer = {"active": active_subagents(sessions, chats, sys.argv[1])}
    except Exception:
        # Never return exception details: authentication and registry data
        # are private, and the plugin only needs a small failure signal.
        answer = {"active": [], "error": "Activity feed unavailable"}
    print(json.dumps(answer))
