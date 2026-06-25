# cn_report.py
# Computing Node telemetry sender: random application telemetry (battery/CPU/queue) over ChT/ChINT.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import json
import os
import socket
import sys
import time

PORT_ChINT = 5003

def main():
    if len(sys.argv) < 3:
        print("usage: cn_report.py <node_name> <dst_ip> [period_s=2]")
        sys.exit(1)
    node = sys.argv[1]
    dst = sys.argv[2]
    period = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    seq = 0
    print(f"[{node}] ChINT reports -> {dst}:{PORT_ChINT} every {period}s", flush=True)
    while True:
        seq += 1
        report = {
            "node": node,
            "seq": seq,
            "load1": round(os.getloadavg()[0], 3),
            "ts": round(time.time(), 3),
        }
        sock.sendto(json.dumps(report).encode(), (dst, PORT_ChINT))
        time.sleep(period)

if __name__ == "__main__":
    main()
