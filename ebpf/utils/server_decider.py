# server_decider.py
# Server-side decision maker: reads TN telemetry registers, enforces MTD and sends control over ChP4.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import argparse, json, subprocess, time

PORTS_FILE="/tmp/airborn_ports.json"
CTRL_PORT=5004
TABLE="ingress_mtd_redirect"
ACTION="ingress_redirect_to_tn"
CH_TD=1; CH_INT=3
TN_IPS={"tn1":"10.0.1.11","tn2":"10.0.1.12"}
TN_NODE={"tn1":2,"tn2":3}

def nk(args):
    return subprocess.run(["nikss-ctl"]+args, capture_output=True, text=True)

def batt(node_id, pipe):
    r=nk(["register","get","pipe",pipe,"ingress_battery_reg","index",str(node_id)])
    try:
        j=json.loads(r.stdout)
        return int(j["ingress_battery_reg"][0]["value"]["field0"], 16)
    except Exception:
        return 100

def send_ctrl(msg):
    code=("import socket,sys;"
          "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);"
          "m=sys.argv[1].encode();"
          "[s.sendto(m,(ip,%d)) for ip in ['10.0.1.11','10.0.1.12']]" % CTRL_PORT)
    subprocess.run(["ip","netns","exec","hserver","python3","-c",code,msg],
                   capture_output=True, text=True)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--period",type=float,default=15.0)
    ap.add_argument("--batt-min",type=int,default=40)
    ap.add_argument("--dwell",type=float,default=5.0,help="min. czas miedzy przelaczeniami")
    ap.add_argument("--pipe",default="1")
    a=ap.parse_args()
    ports=json.load(open(PORTS_FILE))
    tn_ifx={"tn1":ports["htn1"],"tn2":ports["htn2"]}
    cn=[ports["hcn1"],ports["hcn2"]]; srv=[ports["hserver"]]

    def enforce(tn):
        for s in srv+cn:
            nk(["table","delete","pipe",a.pipe,TABLE,"key",str(s),str(CH_TD)])
            nk(["table","add","pipe",a.pipe,TABLE,"action","name",ACTION,"key",str(s),str(CH_TD),"data",str(tn_ifx[tn])])
        for s in cn:
            nk(["table","delete","pipe",a.pipe,TABLE,"key",str(s),str(CH_INT)])
            nk(["table","add","pipe",a.pipe,TABLE,"action","name",ACTION,"key",str(s),str(CH_INT),"data",str(tn_ifx[tn])])

    active="tn1"; seq=0; last=0.0
    def announce(reason,b):
        nonlocal seq,last
        seq+=1; last=time.time()
        enforce(active)
        send_ctrl(json.dumps({"active":active,"active_ip":TN_IPS[active],"seq":seq}))
        print(f"[server] #{seq} DECISION active={active} ({reason}) batteries={b}",flush=True)

    b={"tn1":batt(TN_NODE["tn1"],a.pipe),"tn2":batt(TN_NODE["tn2"],a.pipe)}
    announce("start",b)
    while True:
        time.sleep(1.0)
        b={"tn1":batt(TN_NODE["tn1"],a.pipe),"tn2":batt(TN_NODE["tn2"],a.pipe)}
        other="tn2" if active=="tn1" else "tn1"
        now=time.time()
        if now-last>=a.dwell and b[active]<=a.batt_min and b[other]>=b[active]+5:
            reason=f"battery {active}={b[active]}% low, {other}={b[other]}% better"
            active=other; announce(reason,b)
        elif now-last>=a.period:
            active=other; announce("period elapsed",b)

if __name__=="__main__": main()
