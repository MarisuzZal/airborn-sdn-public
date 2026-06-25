# mtd_controller_ebpf.py
# Moving Target Defense controller for NIKSS (mtd_redirect table).
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import argparse
import json
import random
import subprocess
import time

PORTS_FILE = "/tmp/airborn_ports.json"
STATE_FILE = "/tmp/mtd_active.json"
TABLE = "ingress_mtd_redirect"
ACTION = "ingress_redirect_to_tn"
CH_TD = 1
CH_INT = 3

def cli(args):
    return subprocess.run(["nikss-ctl"] + args, capture_output=True, text=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--period", type=float, default=8.0)
    ap.add_argument("--random", action="store_true")
    ap.add_argument("--pipe", default="1")
    a = ap.parse_args()

    ports = json.load(open(PORTS_FILE))
    sources = [ports["hserver"], ports["hcn1"], ports["hcn2"]]
    tns = [("tn1", ports["htn1"], "10.0.1.11"),
           ("tn2", ports["htn2"], "10.0.1.12")]

    idx, seq = 0, 0
    print(f"[MTD] start; TN ifindex={[t[1] for t in tns]}; sources={sources}; "
          f"period {a.period}s{' (random)' if a.random else ''}", flush=True)
    try:
        while True:
            seq += 1
            name, tn_ifx, tn_ip = tns[idx]
            cn_sources = [ports["hcn1"], ports["hcn2"]]
            for s in sources:
                cli(["table", "delete", "pipe", a.pipe, TABLE,
                     "key", str(s), str(CH_TD)])
                cli(["table", "add", "pipe", a.pipe, TABLE,
                     "action", "name", ACTION,
                     "key", str(s), str(CH_TD), "data", str(tn_ifx)])
            for s in cn_sources:
                cli(["table", "delete", "pipe", a.pipe, TABLE,
                     "key", str(s), str(CH_INT)])
                cli(["table", "add", "pipe", a.pipe, TABLE,
                     "action", "name", ACTION,
                     "key", str(s), str(CH_INT), "data", str(tn_ifx)])
            with open(STATE_FILE, "w") as f:
                json.dump({"seq": seq, "active": name, "active_ip": tn_ip,
                           "tn_ifindex": tn_ifx, "ts": round(time.time(), 3)}, f)
            print(f"[MTD] #{seq}: active TN = {name} (ip {tn_ip}, ifindex {tn_ifx})",
                  flush=True)
            idx = (idx + 1) % len(tns)
            wait = a.period * (random.uniform(0.5, 1.5) if a.random else 1.0)
            time.sleep(wait)
    except KeyboardInterrupt:
        for s in sources:
            cli(["table", "delete", "pipe", a.pipe, TABLE, "key", str(s), str(CH_TD)])
        for s in [ports["hcn1"], ports["hcn2"]]:
            cli(["table", "delete", "pipe", a.pipe, TABLE, "key", str(s), str(CH_INT)])
        print("\n[MTD] stop - redirects cleared", flush=True)

if __name__ == "__main__":
    main()
