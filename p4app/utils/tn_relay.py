# tn_relay.py
# Transit Node relay for ChTD/ChINT; active/passive role taken from the control channel.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import json
import socket
import struct
import sys
import threading
import time

CH_TD_PORT  = 5001
CH_INT_PORT = 5003
CTRL_PORT   = 5004
COLLECTOR   = ("10.0.1.1", 5003)
PACKET_OUTGOING = 4
REPORT_EVERY = 5.0

class State:
    def __init__(self, my_ip):
        self.my_ip = my_ip
        self.active = False
        self.seq = -1
    def apply_ctrl(self, active_ip, seq):
        self.active = (active_ip == self.my_ip)
        if seq != self.seq:
            self.seq = seq
            print(f"[{LABEL}] control #{seq}: "
                  f"{'AKTYWNY - transmituje' if self.active else 'NASLUCH'}", flush=True)

def control_listener(st):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", CTRL_PORT))
    while True:
        try:
            data, _ = s.recvfrom(2048)
            m = json.loads(data.decode())
            st.apply_ctrl(m.get("active_ip"), m.get("seq", 0))
        except (ValueError, UnicodeDecodeError, OSError):
            pass

def is_relay_frame(frame, my_ip):
    if len(frame) < 38 or frame[12:14] != b"\x08\x00":
        return False
    proto = frame[23]
    if proto not in (6, 17):
        return False
    if socket.inet_ntoa(frame[30:34]) == my_ip:
        return False
    ihl = (frame[14] & 0x0F) * 4
    off = 14 + ihl
    if len(frame) < off + 4:
        return False
    sport, dport = struct.unpack_from("!HH", frame, off)
    if proto == 6:
        return CH_TD_PORT in (sport, dport)
    return CH_INT_PORT in (sport, dport)

def main():
    if len(sys.argv) < 3:
        print("usage: tn_relay.py <my_ip> <label> [server_ip]"); sys.exit(1)
    my_ip = sys.argv[1]
    global LABEL
    LABEL = sys.argv[2]

    st = State(my_ip)
    threading.Thread(target=control_listener, args=(st,), daemon=True).start()

    raw = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    raw.bind(("eth0", 0))
    raw.settimeout(0.5)
    rep = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    relayed = collected = 0
    last_report = time.time()
    print(f"[{LABEL}] TN relay start (ip={my_ip}); waiting for ChP4 control", flush=True)

    while True:
        try:
            frame, meta = raw.recvfrom(4096)
            if meta[2] != PACKET_OUTGOING and is_relay_frame(frame, my_ip):
                if st.active:
                    raw.send(frame); relayed += 1
                else:
                    collected += 1
        except socket.timeout:
            pass
        now = time.time()
        if now - last_report >= REPORT_EVERY:
            last_report = now
            report = {"node": LABEL, "role": "tn", "active": st.active,
                      "relayed": relayed, "collected": collected, "ts": round(now, 3)}
            rep.sendto(json.dumps(report).encode(), COLLECTOR)
            print(f"[{LABEL}] {'ACTIVE' if st.active else 'listen'} "
                  f"przekazane={relayed} zebrane={collected}", flush=True)

if __name__ == "__main__":
    main()
