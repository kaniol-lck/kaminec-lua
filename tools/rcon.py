import socket
import struct
import sys


def send_packet(sock, request_id, packet_type, body):
    payload = struct.pack("<ii", request_id, packet_type) + body.encode("utf-8") + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(payload)) + payload)


def read_packet(sock):
    raw = sock.recv(4)
    if len(raw) < 4:
        raise RuntimeError("connection closed")
    length = struct.unpack("<i", raw)[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("connection closed")
        data += chunk
    request_id, packet_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8", "replace")
    return request_id, packet_type, body


def main():
    if len(sys.argv) < 5:
        print("usage: rcon.py <host> <port> <password> <command>", file=sys.stderr)
        return 2
    host, port, password, command = sys.argv[1], int(sys.argv[2]), sys.argv[3], " ".join(sys.argv[4:])
    sock = socket.create_connection((host, port), timeout=10)
    try:
        send_packet(sock, 1, 3, password)
        request_id, _, _ = read_packet(sock)
        if request_id == -1:
            print("RCON authentication failed", file=sys.stderr)
            return 1
        send_packet(sock, 2, 2, command)
        _, _, body = read_packet(sock)
        print(body, end="")
        return 0
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
