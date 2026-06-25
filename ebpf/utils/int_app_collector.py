# int_app_collector.py
# INT collector for the eBPF track (application telemetry).
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

import json, socket, struct, sys

MAGIC=b"IT"; META=10; SHIM=4
NODE_NAME={0:"hcn1",1:"hcn2",2:"htn1",3:"htn2"}

def parse_int(data):
    if len(data)<SHIM or data[0:2]!=MAGIC: return [], data
    count=data[2]; off=SHIM; hops=[]
    for _ in range(count):
        if off+META>len(data): break
        nid=data[off]; bat=data[off+1]; cpu=data[off+2]; que=data[off+3]
        ts=int.from_bytes(data[off+4:off+10],"big")
        hops.append({"node":NODE_NAME.get(nid,nid),"battery":bat,
                     "cpu":cpu,"queue":que,"ts":ts})
        off+=META
    return hops, data[off:]

def main():
    port=int(sys.argv[1]) if len(sys.argv)>1 else 5003
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",port))
    print(f"[INT collector] listening UDP/{port}",flush=True)
    while True:
        data,addr=s.recvfrom(4096)
        hops,payload=parse_int(data)
        try: rep=json.loads(payload.decode())
        except: rep={"raw":payload[:30].hex()}
        chain=" -> ".join(
            f"{h['node']}(bat={h['battery']}% cpu={h['cpu']}% q={h['queue']})"
            for h in hops) or "no INT"
        print(f"[{addr[0]}] INT[{len(hops)}]: {chain}   payload={rep}",flush=True)

if __name__ == "__main__":
    main()
