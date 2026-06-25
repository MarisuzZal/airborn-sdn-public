# int_collector.py
# INT collector on the server: parses in-band telemetry carried by the switch.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import json
import socket
import struct
import sys

INT_MAGIC = b"IT"
META_LEN = 22
SHIM_LEN = 4

def parse_int(data):
    if len(data) < SHIM_LEN or data[0:2] != INT_MAGIC:
        return [], data
    count = data[2]
    off = SHIM_LEN
    hops = []
    for _ in range(count):
        if off + META_LEN > len(data):
            break
        sw_id, in_p, out_p = struct.unpack_from("!IHH", data, off)
        ts = int.from_bytes(data[off+8:off+14], "big")
        (lat,) = struct.unpack_from("!I", data, off + 14)
        qd = int.from_bytes(data[off+18:off+21], "big")
        hops.append({"sw": sw_id, "in": in_p, "out": out_p,
                     "ts_us": ts, "lat_us": lat, "qdepth": qd})
        off += META_LEN
    return hops, data[off:]

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5003
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    print(f"[collector] listening UDP/{port}", flush=True)
    while True:
        data, addr = sock.recvfrom(4096)
        hops, payload = parse_int(data)
        try:
            report = json.loads(payload.decode())
        except (ValueError, UnicodeDecodeError):
            report = {"raw": payload.hex()}
        int_str = " | ".join(
            f"sw={h['sw']} {h['in']}->{h['out']} lat={h['lat_us']}us q={h['qdepth']}"
            for h in hops) or "no INT metadata"
        print(f"[{addr[0]}] {report}  ||  INT: {int_str}", flush=True)

if __name__ == "__main__":
    main()
