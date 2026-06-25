# mtd_controller.py
# Moving Target Defense controller: rotates the active Transit Node.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import argparse
import json
import random
import subprocess
import time

TNS = [
    {"name": "tn1", "ip": "10.0.1.11", "port": 2},
    {"name": "tn2", "ip": "10.0.1.12", "port": 3},
]
REDIRECT_INGRESS = [1, 4, 5]
CH_TD = 1
STATE_FILE = "/tmp/mtd_active.json"

def switch_cli(commands, thrift_port):
    proc = subprocess.run(
        ["simple_switch_CLI", "--thrift-port", str(thrift_port)],
        input="\n".join(commands) + "\n",
        capture_output=True, text=True)
    out = proc.stdout
    if "Invalid" in out or "Error" in out:
        print("[MTD] simple_switch_CLI reported a problem:\n" + out, flush=True)
    return out

def activate(tn, thrift_port, seq):
    cmds = ["table_clear MyIngress.mtd_redirect"]
    for ingress in REDIRECT_INGRESS:
        cmds.append(
            f"table_add MyIngress.mtd_redirect redirect_to_tn "
            f"{ingress} {CH_TD} => {tn['port']}")
    switch_cli(cmds, thrift_port)
    with open(STATE_FILE, "w") as f:
        json.dump({"seq": seq, "active": tn["name"],
                   "active_ip": tn["ip"], "ts": round(time.time(), 3)}, f)
    print(f"[MTD] #{seq}: active TN = {tn['name']} ({tn['ip']}, port s1-p{tn['port']})",
          flush=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--period", type=float, default=10.0,
                    help="rotation period [s] (default 10)")
    ap.add_argument("--random", action="store_true",
                    help="random intervals within 0.5..1.5 of the period")
    ap.add_argument("--thrift-port", type=int, default=9090)
    args = ap.parse_args()

    idx = 0
    seq = 0
    print(f"[MTD] start; TN: {[t['name'] for t in TNS]}; period {args.period}s"
          f"{' (losowy)' if args.random else ''}", flush=True)
    try:
        while True:
            seq += 1
            activate(TNS[idx], args.thrift_port, seq)
            idx = (idx + 1) % len(TNS)
            wait = args.period
            if args.random:
                wait = args.period * random.uniform(0.5, 1.5)
            time.sleep(wait)
    except KeyboardInterrupt:
        print("\n[MTD] stop - clearing redirects (traffic returns to direct paths)")
        switch_cli(["table_clear MyIngress.mtd_redirect"], args.thrift_port)

if __name__ == "__main__":
    main()
