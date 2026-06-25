# drone_agent.py
# Random application-telemetry generator writing PSA registers (battery/CPU/queue length).
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import random
import subprocess
import sys
import time

if len(sys.argv) < 2:
    print("usage: drone_agent.py <node_id> [pipe=1] [period_s=2]"); sys.exit(1)
NODE  = sys.argv[1]
PIPE  = sys.argv[2] if len(sys.argv) > 2 else "1"
PER   = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0

def reg_set(name, value):
    r = subprocess.run(["nikss-ctl","register","set","pipe",PIPE,name,
                        "index",NODE,"value",str(value)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[agent {NODE}] error {name}: {r.stderr.strip()}", flush=True)

def main():
    battery = 100
    print(f"[agent] node_id={NODE}, pipe {PIPE}, every {PER}s", flush=True)
    while True:
        battery -= random.randint(0, 4)
        if battery <= 5: battery = 100
        cpu, queue = random.randint(0,100), random.randint(0,50)
        reg_set("ingress_battery_reg", battery)
        reg_set("ingress_cpu_reg",     cpu)
        reg_set("ingress_queue_reg",   queue)
        print(f"[agent {NODE}] battery={battery}% cpu={cpu}% queue={queue}", flush=True)
        time.sleep(PER)

if __name__ == "__main__":
    main()
