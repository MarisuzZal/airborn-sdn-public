# eBPF track — NIKSS + p4c PSA-eBPF

A performance track running in parallel to BMv2: the same idea (a P4 switch for AirBorn),
but with the data plane compiled to **eBPF** and executed in the Linux kernel (TC/XDP). The
BMv2 track remains as a full-featured reference model; the eBPF track is built in
increments, first in a VM, then on a Raspberry Pi.

> A new layer — as with Phase 1 (BMv2), provisioning and compilation may require joint
> debugging. The scripts are a starting point, not a guarantee.

## Environment (separate VM)

```
cd ebpf
vagrant up        # builds NIKSS from source + p4c (apt) - several to a dozen+ minutes
vagrant ssh
```

`provision_ebpf.sh`: dependencies (clang/llvm/libbpf/gmp/elf/jansson) → p4c from the
p4lang packages (for `p4c-ebpf`) → p4c sources (eBPF runtime files) → build NIKSS
(`build_libbpf.sh`, cmake, make, install) → verify `p4c-ebpf`, `nikss-ctl`, `clang`.

## Compile and run

```
cd /vagrant/ebpf
./compile.sh          # p4c-ebpf: P4(PSA) -> C  ;  clang: C -> eBPF object
sudo ./run_demo.sh    # 5 nodes on network namespaces + load pipeline + entries
sudo ./run_demo.sh clean
```

`run_demo.sh` reproduces the topology from the BMv2 track (server + 2×TN + 2×CN in
10.0.1.0/24, static ARP), but without Mininet — it uses `ip netns` and attaches interfaces
to the pipeline with `nikss-ctl add-port`. Forwarding is loaded with
`nikss-ctl table add ingress_ipv4_lpm` entries.

## Differences from the BMv2 track (v1model → PSA)

| Aspect | BMv2 (v1model) | eBPF (PSA/NIKSS) |
|--------|----------------|------------------|
| Architecture | `V1Switch` | `PSA_Switch` (Ingress/Egress Pipeline) |
| Send to port | `standard_metadata.egress_spec` | `send_to_port(ostd, port)` |
| Table names in CP | `MyIngress.ipv4_lpm` | `ingress_ipv4_lpm` (`<control>_` prefix) |
| Control plane | P4Runtime / Thrift | `nikss-ctl` + BPF maps |
| Harness | Mininet + run_exercise.py | `ip netns` + `nikss-ctl add-port` |
| Performance | interpreter (~1 Mbit/s) | native kernel datapath |

## Increment plan on this track

1. **Forwarding** (this step) — `ipv4_lpm`, proof the pipeline works.
2. **Channel classification** — ternary tables on TCP/UDP ports (as in Phase 1).
3. **INT — reduced version.** Note: BMv2 queue metadata (`deq_timedelta`, `deq_qdepth`,
   `ingress_global_timestamp`) have no direct equivalents in eBPF/TC. `switch_id` and ports
   remain; timestamp from `bpf_ktime`, queue depth most likely drops.
4. **MTD** — switching the active TN by updating maps (`nikss-ctl`).
5. **Raspberry Pi** — moving the eBPF object to the board (kernel 6.x).

## Step 1 result — forwarding on eBPF WORKS

The PSA-eBPF pipeline loaded into the kernel (`nikss-ctl pipeline load`), 5 ports attached,
`ingress_ipv4_lpm` entries added. Test:

```
ping hcn1 -> hserver: 3/3, 0% loss, rtt avg 0.033 ms
```

### Compilation workarounds (captured in provision_ebpf.sh)

The generated p4c runtime code expects included modules (libbpf, bpftool) that a shallow
clone does not fetch. Instead of the fragile `build_libbpf` (which needs bpftool and nested
submodules) we substitute system headers:

| Missing header | Fix |
|----------------|-----|
| `sys/types.h` | `clang -idirafter /usr/include/x86_64-linux-gnu` |
| `gnu/stubs-32.h` | the `gcc-multilib` package |
| `install/libbpf/include/bpf/bpf_endian.h` | `libbpf-dev` + symlink to `runtime/install/libbpf/include/bpf` |
| `contrib/bpftool/include/uapi/linux/bpf.h` | symlink `/usr/include/linux/*.h` into `runtime/contrib/bpftool/include/uapi/linux` |

`nikss-ctl` syntax: action via `action name <name>`, object names with the control prefix
(`ingress_ipv4_lpm`, `ingress_ipv4_forward`).

The `libbpf ... BTF (-524) ... Retrying without BTF` warnings are harmless — the pipeline
loads correctly.

## Throughput measurement (iperf3) — eBPF vs BMv2

| Track | Throughput hcn1 → hserver |
|-------|---------------------------|
| BMv2 (interpreter) | ~1 Mbit/s |
| eBPF / NIKSS (kernel datapath) | **~4 Gbit/s** (sender 4.05 Gbit/s, peaks 5 Gbit/s, Retr ≈ 0) |

A ~4000× difference with an identical P4 program and hardware — confirming the eBPF track
as the performance layer and the basis for the Raspberry Pi.

Operational note: on veth interfaces offloads must be disabled
(`ethtool -K ... gso off gro off tso off tx off rx off`) — otherwise large TCP segments are
lost on the datapath and the transfer stalls after the handshake. Wired permanently into
`run_demo.sh`.

## Step 2 — channel classification (eBPF)

The PSA program is extended with a TCP/UDP parser, the `channel_classify_tcp` and
`channel_classify_udp` tables (match on destination port) and a PSA `channel_ctr` counter
per channel. The classification entries are loaded by `run_demo.sh`.

Reading the counters (after generating traffic on a given port):

```
sudo nikss-ctl counter get pipe 1 ingress_channel_ctr
```

Indices: 1=ChTD(5001/TCP) 2=ChT(5002/TCP) 3=ChINT(5003/UDP) 4=ChP4(5004/TCP)
5=ChCrypto(5005/TCP).

### Step 2 result

Test: iperf3 on ChTD (port 5001), reading `ingress_channel_ctr`:

| Index (channel) | Packets | Interpretation |
|-----------------|---------|----------------|
| 1 (ChTD) | ~2,352,158 | the iperf data stream on 5001 — classified ✓ |
| 0 (UNKNOWN) | ~149,489 | return traffic (ACKs) — ephemeral destination port |
| 2–5 | 0 | no traffic on these channels |

Throughput with classification: ~4.3 Gbit/s (the tables do not burden the datapath). The
return traffic in index 0 is closed in the next step, as on BMv2 — a classification entry
on the source port (`srcPort 5001 → ChTD`).

### Step 2b — return traffic ✓

The `channel_classify_*_src` tables (source port, with a `!hit` fallback on the destination
port) close the classification both ways. Verification (iperf on ChTD):

| Index | Packets | Interpretation |
|-------|---------|----------------|
| 1 (ChTD) | ~1,425,822 | data + ACKs, both directions ✓ |
| 0 (UNKNOWN) | 6 | only the ICMP ping from run_demo.sh |

Throughput: 4.6 Gbit/s, Retr 0 — the fallback has no performance impact.

## Step 3 — INT on eBPF (reduced)

The PSA program is extended with `int_shim` + `int_meta` headers (22 B format compatible
with the BMv2 track). On the ChINT channel (the `int_config` table) the switch appends
switch_id, ingress/egress ports and a timestamp (`ingress_timestamp`), updating the IP/UDP
lengths. The `hop_latency` and `q_depth` fields are zeroed — eBPF/TC does not expose them
(a deliberate limitation of this track).

Thanks to the matching format the **same** `int_collector.py` as on BMv2 works.

Test (in the VM, after `compile.sh` + `run_demo.sh`):

```
sudo ip netns exec hserver python3 /vagrant/p4app/utils/int_collector.py > /tmp/int.log 2>&1 &
sudo ip netns exec hcn1 python3 /vagrant/p4app/utils/cn_report.py cn1 10.0.1.1 2 &
sleep 6
sudo cat /tmp/int.log
```

Expected: lines `... || INT: sw=1 <in>-><out> lat=0us q=0` (lat/q zeroed).

## Step 3 (variant) — INT carries the drone's APPLICATION telemetry

By request: instead of network metadata, INT carries abstract node-state data produced by
an application — battery level, CPU load, task-queue length. The flow follows the spirit of
INT:

```
application agent (drone)  --nikss-ctl register set-->  switch registers
                                                              |
ChINT (UDP/5003)  -->  the switch reads the registers and injects them into INT
                                                              |
                                                      SDN server (collector)
```

INT entry format (16 B): switch_id(4) ingress_port(2) battery(1) cpu(1) queue_len(2)
ingress_ts(6). The `battery_reg`/`cpu_reg`/`queue_reg` registers (index 0) are fed by the
application; the switch only reads them — the application "points at the data for INT" and
the network delivers it without the app modifying the packet.

Components (eBPF track):
- `ebpf/utils/drone_agent.py` — randomly generates telemetry and writes it to registers.
- `ebpf/utils/int_app_collector.py` — collector parsing the application telemetry.

Test (in the VM, after `compile.sh` + `run_demo.sh`):

```
# 1) agent feeds the registers (root, in the default namespace)
sudo python3 /vagrant/ebpf/utils/drone_agent.py 1 2 &
# 2) collector on the server
sudo ip netns exec hserver python3 /vagrant/ebpf/utils/int_app_collector.py > /tmp/int.log 2>&1 &
# 3) the drone sends reports on ChINT
sudo ip netns exec hcn1 python3 /vagrant/p4app/utils/cn_report.py cn1 10.0.1.1 2 &
sleep 6
sudo cat /tmp/int.log
```

Expected: lines `INT sw=1 port=<n> | battery=..% cpu=..% queue=..` — the values change over
time in line with the agent.

### Step 3 result (application telemetry) — WORKS

The agent generates telemetry at random and writes it to registers; the switch injects it
into INT on ChINT; the server receives it:

```
[10.0.1.21] INT sw=1 port=36 | battery=95% cpu=34% queue=8   (payload: cn1 ...)
```

The values in INT match those generated by the agent. The chain: application → switch
registers → INT → SDN server.

Encountered and solved in this step:
- the PSA types `PortId_t`/`Timestamp_t` do not cast directly to `bit<>` — cast via the
  underlying type: `(bit<16>)(PortIdUint_t)...`.
- reading a register by a literal index → C `&0` (error) — read by a variable `ridx`.
- changing `totalLen` without recomputing the IPv4 checksum → the kernel drops the packet
  (bad checksum) — added `InternetChecksum` in the ingress deparser.

## Step 4 — MTD on eBPF (active-TN rotation)

The `mtd_redirect` table (key: ingress_port + channel_id) overrides the ChTD route onto
the active TN port. The `ebpf/utils/mtd_controller_ebpf.py` controller rotates the active
TN, rewriting entries via `nikss-ctl table add/delete`. It reads port ifindexes from
`/tmp/airborn_ports.json` (written by run_demo.sh). The TN relay is the same generic
`p4app/utils/tn_relay.py` (reading `/tmp/mtd_active.json`). Traffic from a TN is not
redirected → no loops.

Test (in the VM, after `compile.sh` + `run_demo.sh`):

```
# relays on the TNs
# NOTE: outside Mininet (ip netns) we pass the IP, not the host name
sudo ip netns exec htn1 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.11 tn1 &
sudo ip netns exec htn2 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.12 tn2 &
# ChTD traffic (iperf 30 s)
sudo ip netns exec hserver iperf3 -s -p 5001 -D
sudo ip netns exec hcn1 iperf3 -c 10.0.1.1 -p 5001 -t 30 -i 5 &
# MTD controller (rotation every 8 s)
sudo python3 /vagrant/ebpf/utils/mtd_controller_ebpf.py --period 8
```

Expected: the controller logs tn1↔tn2 rotations; the `relayed` counter in the relays grows
only on the ACTIVE TN; iperf survives the rotations (brief hiccups).

### Step 4 result (MTD) — WORKS

The controller rotates tn1↔tn2 every 8 s; the active TN transmits (`relayed` grows), the
passive one stalls. ChTD iperf survived all rotations, ~500 Mbit/s for 30 s (the limit is
the Python TN relay, not the switch; in the target system that role is played by
hardware/radio). Retransmissions at the hard handover — as on BMv2.

Environment pitfall: outside Mininet (`ip netns`) there is no host-name-to-IP substitution
— the `tn_relay.py` relays are given an IP address, not a node name.

## Step 5 — 2-slot INT: CN + TN (transit) telemetry

Implementation of the target model (CN source, TN transit, server sink/decision maker):

- the **CN** sends a ChINT report; on the 1st pass the switch appends an INT entry with the
  CN telemetry (`node_map`: port→node_id, per-node registers), `count=1`.
- the packet goes through the **active TN** (mtd_redirect extended with the ChINT channel);
  the TN retransmits it (`tn_relay.py` now also relays UDP/5003).
- on the 2nd pass (ingress from the TN) the switch **appends a second entry** with the TN
  telemetry, `count=2`. Traffic from a TN is not redirected → it reaches the server with
  **two INT entries** (CN + TN).
- the **server** (`int_app_collector.py`) reads both entries.

Format: shim(4B) + up to 2× entry(10B): node_id, battery, cpu, queue, ts(6B). The telemetry
is fed by agents: `drone_agent.py <node_id>` (0=hcn1, 1=hcn2, 2=htn1, 3=htn2).

Decisions (who is active) are made by the server — in this step still via shared state
(`/tmp/mtd_active.json`); the control channel over the network (server→ChP4) is the next
increment.

Test (in the VM, after `compile.sh` + `run_demo.sh`):

```
# telemetry agents (root, default namespace - they write to registers)
sudo python3 /vagrant/ebpf/utils/drone_agent.py 0 1 2 &   # hcn1
sudo python3 /vagrant/ebpf/utils/drone_agent.py 2 1 2 &   # htn1
sudo python3 /vagrant/ebpf/utils/drone_agent.py 3 1 2 &   # htn2
# TN relays (relay ChTD and ChINT)
sudo ip netns exec htn1 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.11 tn1 &
sudo ip netns exec htn2 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.12 tn2 &
# collector on the server
sudo ip netns exec hserver python3 /vagrant/ebpf/utils/int_app_collector.py > /tmp/int.log 2>&1 &
# CN sends ChINT reports
sudo ip netns exec hcn1 python3 /vagrant/p4app/utils/cn_report.py cn1 10.0.1.1 2 &
# MTD controller (adds the ChINT redirect through the active TN)
sudo python3 /vagrant/ebpf/utils/mtd_controller_ebpf.py --period 8 &
sleep 10
sudo cat /tmp/int.log
```

Expected: `INT[2]: hcn1(bat=..) -> htn1(bat=..)` (or htn2 depending on the active TN) — two
telemetry entries on the CN→TN→server path.

### Step 5 result (2-slot INT) — WORKS

The CN→TN→server chain carries two telemetry entries:

```
INT[2]: hcn1(bat=94% cpu=85% q=36) -> htn1(bat=100% cpu=87% q=17)   (cn1 seq 2)
INT[2]: hcn1(bat=83% cpu=85% q=2)  -> htn2(bat=84% cpu=40% q=42)    (cn1 seq 6)
```

The transit TN follows the MTD rotation (tn1→htn1, tn2→htn2). The values match the agents.
A TN's own reports: INT[1] (a single hop).

Compilation fix: `lookahead<bit<16>>()` is not supported by the eBPF backend (it lowers to
an extract onto a scalar) — replaced with `lookahead<int_shim_t>().magic` (a header/struct
type lookahead).

## Step 6 — control channel over the network (the server decides)

Instead of the shared `/tmp/mtd_active.json` file, the server's decision travels as a
**real packet** on ChP4 (UDP/5004) — a prerequisite on separate boards.

- `ebpf/utils/server_decider.py` (server, INT sink): receives telemetry (5003), knows the
  TN batteries, DECIDES who is active (battery < threshold → switch; fallback after a
  period) and ANNOUNCES the decision on ChP4 to the TN nodes. In the VM it also enforces it
  on `mtd_redirect` (on hardware that role is taken by a control receiver on the CN). It
  replaces the collector + MTD controller.
- `p4app/utils/tn_relay.py`: the active/listen state is now set by a **control message from
  the network** (a UDP/5004 listener thread), not a file.

A closed loop: INT (telemetry) → server decision → ChP4 message → nodes.

Test (in the VM, after `compile.sh` + `run_demo.sh`):

```
sudo python3 /vagrant/ebpf/utils/drone_agent.py 0 1 2 &   # hcn1
sudo python3 /vagrant/ebpf/utils/drone_agent.py 2 1 2 &   # htn1
sudo python3 /vagrant/ebpf/utils/drone_agent.py 3 1 2 &   # htn2
sudo ip netns exec htn1 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.11 tn1 &
sudo ip netns exec htn2 python3 /vagrant/p4app/utils/tn_relay.py 10.0.1.12 tn2 &
sudo ip netns exec hcn1 python3 /vagrant/p4app/utils/cn_report.py cn1 10.0.1.1 2 &
# INT collector (shows the CN->TN chain)
sudo ip netns exec hserver python3 /vagrant/ebpf/utils/int_app_collector.py &
# server decision maker: DEFAULT ns (nikss-ctl works only there), battery from registers
sudo python3 /vagrant/ebpf/utils/server_decider.py --period 15 --batt-min 40
```

Note: `server_decider` runs in the DEFAULT ns (without `ip netns exec`), because NIKSS
exposes the pipeline only in the namespace where it was loaded. It reads batteries from the
registers and sends control via `ip netns exec hserver`.

Expected: the server logs `DECISION active=tnX (reason)`, the relays react to the network
message (`control #n: ACTIVE/listen`), and when the active TN's battery drops the server
switches to the healthier one.

### Step 6 result — WORKS (control channel over the network)

```
INT[2]: hcn1(bat=79%) -> htn1(bat=91%)   (tn1 active)
INT[2]: hcn1(bat=74%) -> htn2(bat=58%)   (after switching to tn2)
```

Full loop: the server (default ns) reads batteries from the registers → decides → enforces
mtd_redirect → announces on ChP4 → the TNs react from the network (`control #n`). The active
TN relays symmetrically (tn1 and tn2). The shared file is eliminated.

LESSON (important for hardware): `nikss-ctl` can access the pipeline ONLY in the network
namespace where it was loaded. In the VM (everything in one box) this forced: the decision
maker in the default ns, batteries via `register get`, control via `ip netns exec hserver`.
ON THE BOARDS this problem disappears — each node has its own pipeline in its own default
ns, so the server sends control directly over the network and the CN reacts with a local
`nikss-ctl`. The distributed model is CLEANER than the VM.

## eBPF track status: ARCHITECTURE COMPLETE (in the VM)

Forwarding (~4.6 Gbit/s) + channel classification + 2-slot INT (CN source, TN transit with
its own telemetry) + MTD + server→ChP4 control channel. The whole data and control model is
verified. Next stage: moving to the Raspberry Pi.
