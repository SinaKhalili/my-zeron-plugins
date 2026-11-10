import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import time

LIMIT = 8 * 1024 * 1024

class EngineIPC:
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

    def request(self, method, params=None, stream=False):
        self.send({"id": 1, "method": method, "params": params or {}})
        self.sock.settimeout(30)
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                for line in self.receive().splitlines():
                    frame = json.loads(line)
                    if frame.get("id") != 1:
                        continue
                    if frame.get("err"):
                        raise ValueError("The local usage feed is unavailable")
                    if stream and "item" in frame:
                        return frame["item"]
                    if not stream and "ok" in frame:
                        return frame["ok"]
            raise TimeoutError("The local usage feed timed out")
        finally:
            try:
                if stream: self.send({"id": 1, "cancel": True})
            finally:
                self.sock.close()
