"""Read USB/IP export metadata only; never imports a device or submits USB I/O."""

import argparse
import json
import socket
import struct


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise RuntimeError("USB/IP connection closed before the metadata was complete")
        result.extend(part)
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("--port", type=int, default=3240)
    args = parser.parse_args()
    with socket.create_connection((args.host, args.port), timeout=5) as connection:
        connection.sendall(struct.pack("!HHI", 0x0111, 0x8005, 0))
        version, operation, status, count = struct.unpack("!HHII", read_exact(connection, 12))
        if (version, operation, status) != (0x0111, 0x0005, 0) or count > 128:
            raise RuntimeError("Unexpected USB/IP DEVLIST header or device count")
        devices = []
        for _ in range(count):
            raw = read_exact(connection, 312)
            bus_id = raw[256:288].split(b"\0", 1)[0].decode("utf-8", errors="replace")
            bus, address, speed, vendor, product = struct.unpack_from("!IIIHH", raw, 288)
            interface_count = raw[311]
            read_exact(connection, interface_count * 4)
            devices.append({
                "busId": bus_id,
                "vendorId": f"{vendor:04X}",
                "productId": f"{product:04X}",
                "speed": speed,
                "bus": bus,
                "address": address,
                "interfaces": interface_count,
            })
    print(json.dumps({"host": args.host, "port": args.port, "devices": devices}, ensure_ascii=False))


if __name__ == "__main__":
    main()
